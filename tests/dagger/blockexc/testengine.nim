import std/sequtils
import std/random

import pkg/stew/byteutils
import pkg/asynctest
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/errors

import pkg/dagger/rng
import pkg/dagger/blockexc
import pkg/dagger/stores/network/protobuf/blockexc as pb
import pkg/dagger/stores/network/pendingblocks
import pkg/dagger/stores/network/engine/payments
import pkg/dagger/stores/network/protobuf/presence
import pkg/dagger/stores/memorystore
import pkg/dagger/chunker
import pkg/dagger/blocktype as bt

import ../helpers
import ../examples

suite "BlockExc engine basic":
  let
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerID.init(seckey.getKey().tryGet()).tryGet()
    chunker = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks = chunker.mapIt( !bt.Block.new(it) )
    wallet = WalletRef.example

  var
    done: Future[void]

  setup:
    done = newFuture[void]()

  test "should send want list to new peers":
    proc sendWantList(
      id: PeerID,
      cids: seq[Cid],
      priority: int32 = 0,
      cancel: bool = false,
      wantType: WantType = WantType.wantHave,
      full: bool = false,
      sendDontHave: bool = false) {.gcsafe.} =
        check cids == blocks.mapIt( it.cid )

        done.complete()

    let request = BlockExcRequest(
      sendWantList: sendWantList,
    )

    let engine = BlockExcEngine.new(MemoryStore.new(blocks), wallet, request)
    engine.wantList = blocks.mapIt( it.cid )
    engine.setupPeer(peerId)

    await done

  test "sends account to new peers":
    let pricing = Pricing.example

    proc sendAccount(peer: PeerID, account: Account) =
      check account.address == pricing.address
      done.complete()

    let request = BlockExcRequest(sendAccount: sendAccount)
    let engine = BlockExcEngine.new(MemoryStore.new, wallet, request)
    engine.pricing = pricing.some

    engine.setupPeer(peerId)
    await done.wait(100.millis)

suite "BlockExc engine handlers":
  let
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerID.init(seckey.getKey().tryGet()).tryGet()
    chunker = newRandomChunker(Rng.instance(), size = 1024, chunkSize = 256)
    blocks = chunker.mapIt( !bt.Block.new(it) )
    wallet = WalletRef.example

  var
    engine: BlockExcEngine
    peerCtx: BlockExcPeerCtx
    done: Future[void]

  setup:
    done = newFuture[void]()
    engine = BlockExcEngine.new(MemoryStore.new(), wallet)
    peerCtx = BlockExcPeerCtx(
      id: peerId
    )
    engine.peers.add(peerCtx)

  test "should handle want list":
    let  wantList = makeWantList(blocks.mapIt( it.cid ))
    proc taskScheduler(ctx: BlockExcPeerCtx): bool =
      check ctx.id == peerId
      check ctx.peerWants.mapIt( it.cid ) == blocks.mapIt( it.cid )

      done.complete()

    engine.scheduleTask = taskScheduler
    engine.wantListHandler(peerId, wantList)

    await done

  test "should handle want list - `dont-have`":
    let  wantList = makeWantList(blocks.mapIt( it.cid ), sendDontHave = true)
    proc sendPresence(peerId: PeerID, presence: seq[BlockPresence]) =
      check presence.mapIt( it.cid ) == wantList.entries.mapIt( it.`block` )
      for p in presence:
        check:
          p.`type` == BlockPresenceType.presenceDontHave

      done.complete()

    engine.request = BlockExcRequest(
        sendPresence: sendPresence
    )

    engine.wantListHandler(peerId, wantList)

    await done

  test "should handle want list - `dont-have` some blocks":
    let  wantList = makeWantList(blocks.mapIt( it.cid ), sendDontHave = true)
    proc sendPresence(peerId: PeerID, presence: seq[BlockPresence]) =
      check presence.mapIt( it.cid ) == blocks[2..blocks.high].mapIt( it.cid.data.buffer )
      for p in presence:
        check:
          p.`type` == BlockPresenceType.presenceDontHave

      done.complete()

    engine.request = BlockExcRequest(sendPresence: sendPresence)
    engine.localStore.putBlocks(@[blocks[0], blocks[1]])
    engine.wantListHandler(peerId, wantList)

    await done

  test "stores blocks in local store":
    let pending = blocks.mapIt(
      engine.pendingBlocks.addOrAwait( it.cid )
    )

    engine.blocksHandler(peerId, blocks)
    let resolved = await allFinished(pending)
    check resolved.mapIt( it.read ) == blocks
    for b in blocks:
      check engine.localStore.hasBlock(b.cid)

  test "sends payments for received blocks":
    let account = Account(address: EthAddress.example)
    let peerContext = engine.getPeerCtx(peerId)
    peerContext.account = account.some
    peerContext.peerPrices = blocks.mapIt((it.cid, rand(uint16).u256)).toTable

    engine.request.sendPayment = proc(receiver: PeerID, payment: SignedState) =
      let amount = blocks.mapIt(peerContext.peerPrices[it.cid]).foldl(a+b)
      let balances = !payment.state.outcome.balances(Asset)
      check receiver == peerId
      check balances[account.address.toDestination] == amount
      done.complete()

    engine.blocksHandler(peerId, blocks)

    await done.wait(100.millis)

  test "should handle block presence":
    let price = UInt256.example
    engine.blockPresenceHandler(
      peerId,
      blocks.mapIt(
        PresenceMessage.init(
          Presence(
            cid: it.cid,
            have: true,
            price: price
      ))))

    for cid in blocks.mapIt(it.cid):
      check peerCtx.peerHave.contains(cid)
      check peerCtx.peerPrices[cid] == price

suite "Task Handler":

  let
    rng = Rng.instance()
    chunker = newRandomChunker(Rng.instance(), size = 2048, chunkSize = 256)
    blocks = chunker.mapIt( !bt.Block.new(it) )
    wallet = WalletRef.example

  var
    engine: BlockExcEngine
    peersCtx: seq[BlockExcPeerCtx]
    peers: seq[PeerID]
    done: Future[void]

  setup:
    done = newFuture[void]()
    engine = BlockExcEngine.new(MemoryStore.new(), wallet)
    peersCtx = @[]

    for i in 0..3:
      let seckey = PrivateKey.random(rng[]).tryGet()
      peers.add(PeerID.init(seckey.getKey().tryGet()).tryGet())

      peersCtx.add(BlockExcPeerCtx(
        id: peers[i]
      ))

    engine.peers = peersCtx
    engine.pricing = Pricing.example.some

  test "Should send want-blocks in priority order":
    proc sendBlocks(
      id: PeerID,
      blks: seq[bt.Block]) {.gcsafe.} =
      check blks.len == 2
      check:
        blks[1].cid == blocks[0].cid
        blks[0].cid == blocks[1].cid

    engine.localStore.putBlocks(blocks)
    engine.request.sendBlocks = sendBlocks

    # second block to send by priority
    peersCtx[0].peerWants.add(
      Entry(
        `block`: blocks[0].cid.data.buffer,
        priority: 49,
        cancel: false,
        wantType: WantType.wantBlock,
        sendDontHave: false)
    )

    # first block to send by priority
    peersCtx[0].peerWants.add(
      Entry(
        `block`: blocks[1].cid.data.buffer,
        priority: 50,
        cancel: false,
        wantType: WantType.wantBlock,
        sendDontHave: false)
    )

    await engine.taskHandler(peersCtx[0])

  test "Should send presence":
    let present = blocks
    let missing = @[!bt.Block.new("missing".toBytes)]
    let price = (!engine.pricing).price

    proc sendPresence(id: PeerID, presence: seq[BlockPresence]) =
      check presence.mapIt(!Presence.init(it)) == @[
        Presence(cid: present[0].cid, have: true, price: price),
        Presence(cid: present[1].cid, have: true, price: price),
        Presence(cid: missing[0].cid, have: false)
      ]

    engine.localStore.putBlocks(blocks)
    engine.request.sendPresence = sendPresence

    # have block
    peersCtx[0].peerWants.add(
      Entry(
        `block`: present[0].cid.data.buffer,
        priority: 1,
        cancel: false,
        wantType: WantType.wantHave,
        sendDontHave: false)
    )

    # have block
    peersCtx[0].peerWants.add(
      Entry(
        `block`: present[1].cid.data.buffer,
        priority: 1,
        cancel: false,
        wantType: WantType.wantHave,
        sendDontHave: false)
    )

    # don't have block
    peersCtx[0].peerWants.add(
      Entry(
        `block`: missing[0].cid.data.buffer,
        priority: 1,
        cancel: false,
        wantType: WantType.wantHave,
        sendDontHave: false)
    )

    await engine.taskHandler(peersCtx[0])