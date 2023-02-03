import pkg/chronos
import pkg/upraises
import pkg/stint
import ./statemachine
import ./reservations
import ../contracts/requests

proc newSalesAgent*(sales: Sales,
                    requestId: RequestId,
                    slotIndex: UInt256,
                    availability: ?Availability,
                    request: ?StorageRequest): SalesAgent =
  SalesAgent(
    sales: sales,
    requestId: requestId,
    availability: availability,
    slotIndex: slotIndex,
    request: request)

proc subscribeCancellation*(agent: SalesAgent): Future[void] {.gcsafe.}
proc subscribeFailure*(agent: SalesAgent): Future[void] {.gcsafe.}
proc subscribeSlotFilled*(agent: SalesAgent): Future[void] {.gcsafe.}

proc retrieveRequest(agent: SalesAgent) {.async.} =
  if agent.request.isNone:
    agent.request = await agent.sales.market.getRequest(agent.requestId)

proc start*(agent: SalesAgent, numSlots: uint64) {.async.} =
  # TODO: try not to block the thread waiting for the network
  await agent.retrieveRequest()
  await agent.subscribeCancellation()
  await agent.subscribeFailure()
  await agent.subscribeSlotFilled()

proc stop*(agent: SalesAgent) {.async.} =
  try:
    await agent.fulfilled.unsubscribe()
  except CatchableError:
    discard
  try:
    await agent.failed.unsubscribe()
  except CatchableError:
    discard
  try:
    await agent.slotFilled.unsubscribe()
  except CatchableError:
    discard
  if not agent.cancelled.completed:
    await agent.cancelled.cancelAndWait()

proc subscribeCancellation*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onCancelled() {.async.} =
    let clock = agent.sales.clock

    without request =? agent.request:
      return

    await clock.waitUntil(request.expiry.truncate(int64))
    await agent.fulfilled.unsubscribe()
    without state =? (agent.state as SaleState):
      return
    await state.onCancelled(request)

  agent.cancelled = onCancelled()

  proc onFulfilled(_: RequestId) {.async.} =
    agent.cancelled.cancel()

  agent.fulfilled =
    await market.subscribeFulfillment(agent.requestId, onFulfilled)

proc subscribeFailure*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onFailed(_: RequestId) {.async.} =
    without request =? agent.request and
            state =? (agent.state as SaleState):
      return

    await agent.failed.unsubscribe()
    await state.onFailed(request)

  agent.failed =
    await market.subscribeRequestFailed(agent.requestId, onFailed)

proc subscribeSlotFilled*(agent: SalesAgent) {.async.} =
  let market = agent.sales.market

  proc onSlotFilled(requestId: RequestId,
                    slotIndex: UInt256) {.async.} =
    without state =? (agent.state as SaleState):
      return

    await agent.slotFilled.unsubscribe()
    await state.onSlotFilled(requestId, agent.slotIndex)

  agent.slotFilled =
    await market.subscribeSlotFilled(agent.requestId,
                                     agent.slotIndex,
                                     onSlotFilled)
