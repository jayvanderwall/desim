import unittest

import desim
import sequtils
import random
import sugar

randomize()

#
# Component with self loop
#

type
  TestSelfComponent = ref object of Component
    counter: int
    selfLink: Link[bool]
    selfPort: Port[bool]


proc newTestSelfComponent(): TestSelfComponent =
  TestSelfComponent(selfLink: newLink[bool](1), selfPort: newPort[bool]())


component comp, TestSelfComponent:

  startup:
    comp.selfLink.send(true)

  for msg in messages(comp.selfPort):
    comp.counter += 1


test "Component with self loop":

  var
    sim = newSimulator()

  let
    comp = newTestSelfComponent()

  sim.register comp
  connect(comp.selfLink, comp.selfPort)

  sim.run()

  check(comp.counter == 1)


#
# Two components communicating
#


type
  TestSendComponent = ref object of Component
    msg: int
    sendLink: Link[int]

  TestRecvComponent = ref object of Component
    msg: int
    recvPort: Port[int]


proc newTestSendComponent(msg: int): TestSendComponent =
  TestSendComponent(msg: msg, sendLink: newLink[int](1))


proc newTestRecvComponent(): TestRecvComponent =
  TestRecvComponent(recvPort: newPort[int]())


component comp, TestSendComponent:
  startup:
    comp.sendLink.send(comp.msg)


component comp, TestRecvComponent:
  for msg in messages(comp.recvPort):
    comp.msg = msg


test "Two Components communicating":
  var
    sim = newSimulator()

  let
    sendComp = newTestSendComponent(42)
    recvComp = newTestRecvComponent()

  sim.register sendComp
  sim.register recvComp
  connect(sendComp.sendLink, recvComp.recvPort)

  sim.run()

  check(recvComp.msg == sendComp.msg)

#
# Multiple messages with delays
#

type
  MultiMessageSend = ref object of Component
    msgs: seq[(int, SimulationTime)]
    sendLink: Link[int]

  MultiMessageRecv = ref object of Component
    msgs: seq[(int, SimulationTime)]
    recvPort: Port[int]


proc newMultiMessageSend(msgs: seq[(int, SimulationTime)]): MultiMessageSend =
  MultiMessageSend(msgs: msgs, sendLink: newLink[int](1))


proc newMultiMessageRecv(): MultiMessageRecv =
  MultiMessageRecv(recvPort: newPort[int]())


component comp, MultiMessageSend:
  startup:
    for msg in comp.msgs:
      comp.sendLink.send(msg[0], msg[1])

component comp, MultiMessageRecv:
  for msg in messages(comp.recvPort):
    comp.msgs.add (msg, simulator.currentTime - 1)

test "Multiple messages different delays":
  var
    sim = newSimulator()

  let
    sender = newMultiMessageSend(@[(1, 0), (2, 5), (3, 25)])
    receiver = newMultiMessageRecv()

  sim.register sender
  sim.register receiver
  connect(sender.sendLink, receiver.recvPort)

  sim.run()

  for (smsg, rmsg) in zip(sender.msgs, receiver.msgs):
    check(smsg == rmsg)

#
# Broadcast to component
#

type
  TestBcastComponent = ref object of Component
    msg: int
    sendLink: BcastLink[int]


proc newTestBcastComponent(msg: int): TestBcastComponent =
  TestBcastComponent(msg: msg, sendLink: newBcastLink[int](1))


component comp, TestBcastComponent:
  startup:
    comp.sendLink.send(comp.msg)


test "Broadcast to two components":
  var sim = newSimulator()
  let
    sender = newTestBcastComponent(42)
    receivers = [
      newTestRecvComponent(),
      newTestRecvComponent()
    ]

  sim.register sender
  for receiver in receivers:
    sim.register receiver
    connect(sender.sendLink, receiver.recvPort)

  sim.run()

  for idx, receiver in receivers:
    check(receiver.msg == sender.msg)

#
# Random communication
#

type
  RandomComponent = ref object of Component
    input: Port[int]
    outs: seq[Link[int]]
    received: seq[int]
    sent: seq[(int, int)]


proc newRandomComponent(total: int, index: int): RandomComponent =
  RandomComponent(input: newPort[int](),
                  outs: toSeq(0..<total).map(_ => newLink[int](1)))


component comp, RandomComponent:

  startup:
    let
      msg = rand(100)
      dst = rand(comp.outs.len - 1)
    # This may send a message to this component, which is fine.
    comp.outs[dst].send msg
    comp.sent.add (msg, dst)

  for msg in messages(comp.input):
    comp.received.add msg


test "Random Communication between many components":
  var
    sim = newSimulator()
    comps: seq[RandomComponent]

  let
    count = rand(3..20)

  for i in 0..<count:
    var comp = newRandomComponent(count, i)
    sim.register comp
    comps.add comp

  for i in 0..<count:
    for j in i..<count:
      var
        ii = i
        jj = j
      for k in 1..2:
        connect(comps[ii].outs[jj], comps[jj].input)
        swap(ii, jj)

  sim.run()

  for comp in comps:
    for (msg, idx) in comp.sent:
      require(idx >= 0 and idx < comps.len)
      let cidx = comps[idx].received.find msg
      require(cidx != -1)
      comps[idx].received.del cidx

  for comp in comps:
    check(comp.received.len == 0)

#
# BatchLink
#

type
  TestBatchLinkComponent = ref object of Component
    link: BatchLink[int]
    timer: Timer[bool]
    msgs: seq[int]
    index: int


proc newTestBatchLinkComponent(): TestBatchLinkComponent =
  TestBatchLinkComponent(link: newBatchLink[int](), timer: newTimer[bool]())


component comp, TestBatchLinkComponent:

  startup:
    assert comp.msgs.len > 0, "Please test something"
    comp.timer.set true, rand(1..20)

  for _ in messages(comp.timer):
    comp.link.send comp.msgs[comp.index]
    comp.index += 1
    if comp.index < comp.msgs.len:
      comp.timer.set true, rand(1..20)


test "Batch Link":
  var
    sim = newSimulator()
    testBatch = newTestBatchLinkComponent()
    testRecv = newMultiMessageRecv()

  sim.register testBatch
  sim.register testRecv
  connect(testBatch.link, testRecv.recvPort)

  let count = rand(1..10)
  testBatch.msgs = toSeq(1..count).map(_ => rand(-10..10))

  sim.run()

  check(testBatch.msgs.len == testRecv.msgs.len)

  for (expMsg, actMsgTuple) in zip(testBatch.msgs, testRecv.msgs):
    check(expMsg == actMsgTuple[0])

#
# Component with an indirect link
#

type
  IndirectLinkComponent = ref object of Component
    ## This component contains a link that will not automatically have
    ## its back reference set.
    link: (Link[int], int)


proc newIndirectLinkComponent(value: int): IndirectLinkComponent =
  IndirectLinkComponent(link: (newLink[int](1), value))


component comp, IndirectLinkComponent:
  startup:
    comp.link[0].send comp.link[1]


test "Component with indirect link":
  var
    sim = newSimulator()
    expMessage = 7
    sender = newIndirectLinkComponent(expMessage)
    receiver = newTestRecvComponent()

  sim.register sender
  sim.register receiver

  sender.link[0].comp = sender

  connect(sender.link[0], receiver.recvPort)

  sim.run()

  check(expMessage == receiver.msg)

#
# Remaining messages at shutdown
#

type
  SendQuitComponent = ref object of Component
    link: Link[int]
    msg: int
  ReceiveRemainingComponent = ref object of Component
    port: Port[int]
    msgs: seq[int]
    badMsgs: seq[int]

proc newSendQuitComponent(msg: int): SendQuitComponent =
  SendQuitComponent(msg: msg, link: newLink[int](1))

component comp, SendQuitComponent:

  startup:
    comp.link.send comp.msg
    simulator.quit()

proc newReceiveRemainingComponent(): ReceiveRemainingComponent =
  ReceiveRemainingComponent(port: newPort[int]())

component comp, ReceiveRemainingComponent:

  for msg in messages(comp.port):
    comp.badMsgs.add msg

  shutdown:
    for msg, _ in remainingMessages(comp.port):
      comp.msgs.add msg


test "Checking remaining messages at shutdown":
  var
    sim = newSimulator()
    expValue: int = 42
    sender = newSendQuitComponent(expValue)
    receiver = newReceiveRemainingComponent()

  sim.register sender
  sim.register receiver

  connect(sender.link, receiver.port)

  sim.run()

  check(len(receiver.badMsgs) == 0)
  require(len(receiver.msgs) == 1)
  check(sender.msg == receiver.msgs[0])
