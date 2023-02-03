import pkg/questionable
import pkg/questionable/results
import chronicles
import ../statemachine

type SaleErrored* = ref object of SaleState
  error*: ref CatchableError

method `$`*(state: SaleErrored): string = "SaleErrored"

method enterAsync*(state: SaleErrored) {.async.} =
  without agent =? (state.context as SalesAgent):
    raiseAssert "invalid state"

  if onClear =? agent.sales.onClear and
      request =? agent.request and
      slotIndex =? agent.slotIndex:
    onClear(agent.availability, request, slotIndex)

  # TODO: when availability persistence is added, change this to not optional
  # NOTE: with this in place, restoring state for a restarted node will
  # never free up availability once finished. Persisting availability
  # on disk is required for this.
  if availability =? agent.availability:
    # TODO: if future updates `availability.reusable == true` then
    # agent.sales.reservations.markUnused, else
    # agent.sales.reservations.release
    if err =? (await agent.sales.reservations.markUnused(availability)).errorOption:
      raiseAssert "Failed to mark availability unused"

  error "Sale error", error=state.error.msg
