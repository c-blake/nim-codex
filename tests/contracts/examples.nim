import std/times
import pkg/stint
import pkg/ethers
import codex/contracts
import ../examples

export examples

proc example*(_: type Address): Address =
  Address(array[20, byte].example)

proc example*(_: type StorageRequest): StorageRequest =
  StorageRequest(
    client: Address.example,
    ask: StorageAsk(
      slots: 4,
      slotSize: (1 * 1024 * 1024 * 1024).u256, # 1 Gigabyte
      duration: (10 * 60 * 60).u256, # 10 hours
      proofProbability: 4.u256, # require a proof roughly once every 4 periods
      reward: 84.u256,
      maxSlotLoss: 2 # 2 slots can be freed without data considered to be lost
    ),
    content: StorageContent(
      cid: "zb2rhheVmk3bLks5MgzTqyznLu1zqGH5jrfTA1eAZXrjx7Vob",
      erasure: StorageErasure(
        totalChunks: 12,
      ),
      por: StoragePor(
        u: @(array[480, byte].example),
        publicKey: @(array[96, byte].example),
        name: @(array[512, byte].example)
      )
    ),
    expiry: (getTime() + initDuration(hours=1)).toUnix.u256,
    nonce: Nonce.example
  )
