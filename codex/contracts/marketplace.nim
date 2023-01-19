import pkg/ethers
import pkg/json_rpc/rpcclient
import pkg/stint
import pkg/chronos
import ../clock
import ./requests

export stint
export ethers

type
  Marketplace* = ref object of Contract
  StorageRequested* = object of Event
    requestId*: RequestId
    ask*: StorageAsk
  SlotFilled* = object of Event
    requestId* {.indexed.}: RequestId
    slotIndex* {.indexed.}: UInt256
    slotId*: SlotId
  RequestFulfilled* = object of Event
    requestId* {.indexed.}: RequestId
  RequestCancelled* = object of Event
    requestId* {.indexed.}: RequestId
  RequestFailed* = object of Event
    requestId* {.indexed.}: RequestId
  ProofSubmitted* = object of Event
    id*: SlotId
    proof*: seq[byte]


proc collateral*(marketplace: Marketplace): UInt256 {.contract, view.}
proc slashMisses*(marketplace: Marketplace): UInt256 {.contract, view.}
proc slashPercentage*(marketplace: Marketplace): UInt256 {.contract, view.}
proc minCollateralThreshold*(marketplace: Marketplace): UInt256 {.contract, view.}

proc deposit*(marketplace: Marketplace, amount: UInt256) {.contract.}
proc withdraw*(marketplace: Marketplace) {.contract.}
proc balanceOf*(marketplace: Marketplace, account: Address): UInt256 {.contract, view.}

proc requestStorage*(marketplace: Marketplace, request: StorageRequest) {.contract.}
proc fillSlot*(marketplace: Marketplace, requestId: RequestId, slotIndex: UInt256, proof: seq[byte]) {.contract.}
proc withdrawFunds*(marketplace: Marketplace, requestId: RequestId) {.contract.}
proc freeSlot*(marketplace: Marketplace, id: SlotId) {.contract.}
proc getRequest*(marketplace: Marketplace, id: RequestId): StorageRequest {.contract, view.}
proc getHost*(marketplace: Marketplace, id: SlotId): Address {.contract, view.}

proc myRequests*(marketplace: Marketplace): seq[RequestId] {.contract, view.}
proc state*(marketplace: Marketplace, requestId: RequestId): RequestState {.contract, view.}
proc requestEnd*(marketplace: Marketplace, requestId: RequestId): SecondsSince1970 {.contract, view.}

proc proofPeriod*(marketplace: Marketplace): UInt256 {.contract, view.}
proc proofTimeout*(marketplace: Marketplace): UInt256 {.contract, view.}

proc proofEnd*(marketplace: Marketplace, id: SlotId): UInt256 {.contract, view.}
proc missingProofs*(marketplace: Marketplace, id: SlotId): UInt256 {.contract, view.}
proc isProofRequired*(marketplace: Marketplace, id: SlotId): bool {.contract, view.}
proc willProofBeRequired*(marketplace: Marketplace, id: SlotId): bool {.contract, view.}
proc getChallenge*(marketplace: Marketplace, id: SlotId): array[32, byte] {.contract, view.}
proc getPointer*(marketplace: Marketplace, id: SlotId): uint8 {.contract, view.}

proc submitProof*(marketplace: Marketplace, id: SlotId, proof: seq[byte]) {.contract.}
proc markProofAsMissing*(marketplace: Marketplace, id: SlotId, period: UInt256) {.contract.}