import std/sequtils
import pkg/questionable
import pkg/upraises
import pkg/stint
import pkg/nimcrypto
import pkg/chronicles
import ./rng
import ./market
import ./clock
import ./proving
import ./contracts/requests
import ./sales/salescontext
import ./sales/salesagent
import ./sales/availability
import ./sales/statemachine
import ./sales/states/downloading
import ./sales/states/unknown

## Sales holds a list of available storage that it may sell.
##
## When storage is requested on the market that matches availability, the Sales
## object will instruct the Codex node to persist the requested data. Once the
## data has been persisted, it uploads a proof of storage to the market in an
## attempt to win a storage contract.
##
##    Node                        Sales                   Market
##     |                          |                         |
##     | -- add availability  --> |                         |
##     |                          | <-- storage request --- |
##     | <----- store data ------ |                         |
##     | -----------------------> |                         |
##     |                          |                         |
##     | <----- prove data ----   |                         |
##     | -----------------------> |                         |
##     |                          | ---- storage proof ---> |

export stint
export availability

type
  Sales* = ref object
    context*: SalesContext
    subscription*: ?market.Subscription
    available: seq[Availability]
    agents*: seq[SalesAgent]

proc `onStore=`*(sales: Sales, onStore: OnStore) =
  sales.context.onStore = some onStore

proc `onProve=`*(sales: Sales, onProve: OnProve) =
  sales.context.onProve = some onProve

proc `onClear=`*(sales: Sales, onClear: OnClear) =
  sales.context.onClear = some onClear

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.context.onSale = some callback

proc onStore*(sales: Sales): ?OnStore = sales.context.onStore

proc onProve*(sales: Sales): ?OnProve = sales.context.onProve

proc onClear*(sales: Sales): ?OnClear = sales.context.onClear

proc onSale*(sales: Sales): ?OnSale = sales.context.onSale

proc available*(sales: Sales): seq[Availability] = sales.available

proc init*(_: type Availability,
          size: UInt256,
          duration: UInt256,
          minPrice: UInt256): Availability =
  var id: array[32, byte]
  doAssert randomBytes(id) == 32
  Availability(id: id, size: size, duration: duration, minPrice: minPrice)

func add*(sales: Sales, availability: Availability) =
  if not sales.available.contains(availability):
    sales.available.add(availability)
  # TODO: add to disk (persist), serialise to json.

func remove*(sales: Sales, availability: Availability) =
  sales.available.keepItIf(it != availability)
  # TODO: remove from disk availability, mark as in use by assigning
  # a slotId, so that it can be used for restoration (node restart)

func new*(_: type Sales,
          market: Market,
          clock: Clock,
          proving: Proving): Sales =

  let sales = Sales(context: SalesContext(
    market: market,
    clock: clock,
    proving: proving
  ))

  proc onSaleErrored(availability: Availability) =
    sales.add(availability)

  sales.context.onSaleErrored = some onSaleErrored
  sales

func findAvailability*(sales: Sales, ask: StorageAsk): ?Availability =
  for availability in sales.available:
    if ask.slotSize <= availability.size and
       ask.duration <= availability.duration and
       ask.pricePerSlot >= availability.minPrice:
      return some availability

proc randomSlotIndex(numSlots: uint64): UInt256 =
  let rng = Rng.instance
  let slotIndex = rng.rand(numSlots - 1)
  return slotIndex.u256

proc findSlotIndex(numSlots: uint64,
                   requestId: RequestId,
                   slotId: SlotId): ?UInt256 =
  for i in 0..<numSlots:
    if slotId(requestId, i.u256) == slotId:
      return some i.u256

  return none UInt256

proc handleRequest(sales: Sales,
                   requestId: RequestId,
                   ask: StorageAsk) =
  without availability =? sales.findAvailability(ask):
    return
  sales.remove(availability)
  # TODO: check if random slot is actually available (not already filled)
  let slotIndex = randomSlotIndex(ask.slots)
  let agent = newSalesAgent(
    sales.context,
    requestId,
    slotIndex,
    some availability,
    none StorageRequest
  )
  agent.start(SaleDownloading())
  sales.agents.add agent

proc load*(sales: Sales) {.async.} =
  let market = sales.context.market

  # TODO: restore availability from disk
  let slotIds = await market.mySlots()

  for slotId in slotIds:
    # TODO: this needs to be optimised
    if request =? await market.getRequestFromSlotId(slotId):
      let availability = sales.findAvailability(request.ask)
      without slotIndex =? findSlotIndex(request.ask.slots,
                                          request.id,
                                          slotId):
        raiseAssert "could not find slot index"

      let agent = newSalesAgent(
        sales.context,
        request.id,
        slotIndex,
        availability,
        some request)
      agent.start(SaleUnknown())
      sales.agents.add agent

proc start*(sales: Sales) {.async.} =
  doAssert sales.subscription.isNone, "Sales already started"

  proc onRequest(requestId: RequestId, ask: StorageAsk) {.gcsafe, upraises:[].} =
    sales.handleRequest(requestId, ask)

  try:
    sales.subscription = some await sales.context.market.subscribeRequests(onRequest)
  except CatchableError as e:
    error "Unable to start sales", msg = e.msg

proc stop*(sales: Sales) {.async.} =
  if subscription =? sales.subscription:
    sales.subscription = market.Subscription.none
    try:
      await subscription.unsubscribe()
    except CatchableError as e:
      warn "Unsubscribe failed", msg = e.msg

  for agent in sales.agents:
    await agent.stop()
