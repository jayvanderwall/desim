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


proc newTestSelfComponent(sim: Simulator): TestSelfComponent =
  result = TestSelfComponent(
    selfLink: newLink[bool](sim, 1),
    selfPort: newPort[bool](),
  )
  sim.register(result)


component comp, TestSelfComponent:
  useSimulator sim

  startup:
    sim.connect(comp, comp.selfLink, comp, comp.selfPort)
    comp.selfLink.send(true)

  onMessage comp.selfPort, msg:
    comp.counter += 1


test "Component with self loop":

  var
    sim = newSimulator()

  let
    testComp = newTestSelfComponent(sim)

  sim.run()

  check(testComp.counter == 1)


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


proc newTestSendComponent(sim: Simulator, msg: int): TestSendComponent =
  result = TestSendComponent(msg: msg, sendLink: newLink[int](sim, 1))
  sim.register result


proc newTestRecvComponent(sim: Simulator): TestRecvComponent =
  result = TestRecvComponent(recvPort: newPort[int]())
  sim.register result


component comp, TestSendComponent:
  startup:
    comp.sendLink.send(comp.msg)


component comp, TestRecvComponent:
  onMessage comp.recvPort, msg:
    comp.msg = msg


test "Two Components communicating":
  var
    sim = newSimulator()

  let
    sendComp = newTestSendComponent(sim, 42)
    recvComp = newTestRecvComponent(sim)

  sim.connect(sendComp, sendComp.sendLink, recvComp, recvComp.recvPort)

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


proc newMultiMessageSend(sim: Simulator, msgs: seq[(int, SimulationTime)]): MultiMessageSend =
  result = MultiMessageSend(msgs: msgs, sendLink: newLink[int](sim, 1))
  sim.register result


proc newMultiMessageRecv(sim: Simulator): MultiMessageRecv =
  result = MultiMessageRecv(recvPort: newPort[int]())
  sim.register result


component comp, MultiMessageSend:
  startup:
    for msg in comp.msgs:
      comp.sendLink.send(msg[0], msg[1])

component comp, MultiMessageRecv:
  useSimulator sim
  onMessage comp.recvPort, msg:
    comp.msgs.add (msg, sim.currentTime - 1)

test "Multiple messages different delays":
  var
    sim = newSimulator()

  let
    sender = newMultiMessageSend(sim, @[(1, 0), (2, 5), (3, 25)])
    receiver = newMultiMessageRecv(sim)

  sim.connect(sender, sender.sendLink, receiver, receiver.recvPort)

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


proc newTestBcastComponent(sim: Simulator, msg: int): TestBcastComponent =
  result = TestBcastComponent(msg: msg, sendLink: newBcastLink[int](sim, 1))
  sim.register result


component comp, TestBcastComponent:
  startup:
    comp.sendLink.send(comp.msg)


test "Broadcast to two components":
  var sim = newSimulator()
  let
    sender = newTestBcastComponent(sim, 42)
    receivers = [
      newTestRecvComponent(sim),
      newTestRecvComponent(sim)
    ]

  for receiver in receivers:
    sim.connect(sender, sender.sendLink, receiver, receiver.recvPort)

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


proc newRandomComponent(sim: Simulator, total: int, index: int): RandomComponent =
  result = RandomComponent(
    input: newPort[int](),
    outs: toSeq(0..<total).map(_ => newLink[int](sim, 1)),
  )
  sim.register result


component comp, RandomComponent:

  startup:
    let
      msg = rand(100)
      dst = rand(comp.outs.len - 1)
    # This may send a message to this component, which is fine.
    comp.outs[dst].send msg
    comp.sent.add (msg, dst)

  onMessage comp.input, msg:
    comp.received.add msg


test "Random Communication between many components":
  var
    sim = newSimulator()
    comps: seq[RandomComponent]

  let
    count = rand(3..20)

  for i in 0..<count:
    comps.add newRandomComponent(sim, count, i)

  for i in 0..<count:
    for j in i..<count:
      var
        ii = i
        jj = j
      for k in 1..2:
        sim.connect(comps[ii], comps[ii].outs[jj],
                    comps[jj], comps[jj].input)
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


proc newTestBatchLinkComponent(sim: Simulator): TestBatchLinkComponent =
  var
    link = newBatchLink[int](sim)
    timer = newTimer[bool](sim)
  result = TestBatchLinkComponent(link: link,
                                  timer: timer)
  sim.register result


component comp, TestBatchLinkComponent:

  startup:
    assert comp.msgs.len > 0, "Please test something"
    comp.timer.set true, rand(1..20)

  onTimer comp.timer, _:
    comp.link.send comp.msgs[comp.index]
    comp.index += 1
    if comp.index < comp.msgs.len:
      comp.timer.set true, rand(1..20)


test "Batch Link":
  var
    sim = newSimulator()
    testBatch = newTestBatchLinkComponent(sim)
    testRecv = newMultiMessageRecv(sim)

  sim.connect(testBatch, testBatch.link, testRecv, testRecv.recvPort)

  let count = rand(1..10)
  testBatch.msgs = toSeq(1..count).map(_ => rand(-10..10))

  sim.run()

  check(testBatch.msgs.len == testRecv.msgs.len)

  for (expMsg, actMsgTuple) in zip(testBatch.msgs, testRecv.msgs):
    check(expMsg == actMsgTuple[0])
