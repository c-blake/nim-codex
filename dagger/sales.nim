import std/times
import std/sequtils
import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/nimcrypto
import ./market

export stint

const DefaultOfferExpiryInterval = (10 * 60).u256

type
  Sales* = ref object
    market: Market
    subscription: ?Subscription
    available*: seq[Availability]
    offerExpiryInterval*: UInt256
    onSale: ?OnSale
  Availability* = object
    id*: array[32, byte]
    size*: uint64
    duration*: uint64
    minPrice*: UInt256
  Negotiation = ref object
    sales: Sales
    requestId: array[32, byte]
    ask: StorageAsk
    availability: Availability
    offer: ?StorageOffer
    subscription: ?Subscription
    waiting: ?Future[void]
    finished: bool
  OnSale = proc(offer: StorageOffer) {.gcsafe, upraises: [].}

func new*(_: type Sales, market: Market): Sales =
  Sales(market: market, offerExpiryInterval: DefaultOfferExpiryInterval)

proc init*(_: type Availability,
          size: uint64,
          duration: uint64,
          minPrice: UInt256): Availability =
  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: id, size: size, duration: duration, minPrice: minPrice)

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.onSale = some callback

func add*(sales: Sales, availability: Availability) =
  sales.available.add(availability)

func remove*(sales: Sales, availability: Availability) =
  sales.available.keepItIf(it != availability)

func findAvailability(sales: Sales, ask: StorageAsk): ?Availability =
  for availability in sales.available:
    if ask.size <= availability.size.u256 and
       ask.duration <= availability.duration.u256 and
       ask.maxPrice >= availability.minPrice:
      return some availability

proc createOffer(negotiation: Negotiation): StorageOffer =
  StorageOffer(
    requestId: negotiation.requestId,
    price: negotiation.ask.maxPrice,
    expiry: getTime().toUnix().u256 + negotiation.sales.offerExpiryInterval
  )

proc sendOffer(negotiation: Negotiation) {.async.} =
  let offer = negotiation.createOffer()
  negotiation.offer = some await negotiation.sales.market.offerStorage(offer)

proc finish(negotiation: Negotiation, success: bool) =
  if negotiation.finished:
    return

  negotiation.finished = true

  if subscription =? negotiation.subscription:
    asyncSpawn subscription.unsubscribe()

  if waiting =? negotiation.waiting:
    waiting.cancel()

  if success and offer =? negotiation.offer:
    if onSale =? negotiation.sales.onSale:
      onSale(offer)
  else:
    negotiation.sales.add(negotiation.availability)

proc onSelect(negotiation: Negotiation, offerId: array[32, byte]) =
  if offer =? negotiation.offer and offer.id == offerId:
    negotiation.finish(success = true)
  else:
    negotiation.finish(success = false)

proc subscribeSelect(negotiation: Negotiation) {.async.} =
  without offer =? negotiation.offer:
    return
  proc onSelect(offerId: array[32, byte]) {.gcsafe, upraises:[].} =
    negotiation.onSelect(offerId)
  let market = negotiation.sales.market
  let subscription = await market.subscribeSelection(offer.requestId, onSelect)
  negotiation.subscription = some subscription

proc waitForExpiry(negotiation: Negotiation) {.async.} =
  without offer =? negotiation.offer:
    return
  await negotiation.sales.market.waitUntil(offer.expiry)
  negotiation.finish(success = false)

proc start(negotiation: Negotiation) {.async.} =
  let sales = negotiation.sales
  let availability = negotiation.availability
  sales.remove(availability)
  await negotiation.sendOffer()
  await negotiation.subscribeSelect()
  negotiation.waiting = some negotiation.waitForExpiry()

proc handleRequest(sales: Sales,
                   requestId: array[32, byte],
                   ask: StorageAsk) {.async.} =
  without availability =? sales.findAvailability(ask):
    return

  let negotiation = Negotiation(
    sales: sales,
    requestId: requestId,
    ask: ask,
    availability: availability
  )

  asyncSpawn negotiation.start()

proc start*(sales: Sales) =
  doAssert sales.subscription.isNone, "Sales already started"

  proc onRequest(requestId: array[32, byte], ask: StorageAsk) {.gcsafe, upraises:[].} =
    asyncSpawn sales.handleRequest(requestId, ask)

  proc subscribe {.async.} =
    sales.subscription = some await sales.market.subscribeRequests(onRequest)

  asyncSpawn subscribe()

proc stop*(sales: Sales) =
  if subscription =? sales.subscription:
    asyncSpawn subscription.unsubscribe()
    sales.subscription = Subscription.none