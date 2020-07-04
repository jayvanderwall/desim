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

component comp, TestSelfComponent:
  useSimulator sim

  startup:
    sim.connect(comp, comp.selfLink, comp, comp.selfPort)
    comp.selfLink.send(true)

  onMessage comp.selfPort, msg:
    comp.counter += 1

proc makeTestSim(components: seq[Component]): Simulator =
  result = newSimulator()
  for comp in components:
    result.register(comp)

test "Component with self loop":

  let
    testComp = TestSelfComponent(selfPort: Port[bool]())

  var
    components: seq[Component]
  components.add(testComp)

  makeTestSim(components).run()

  check(testComp.counter == 1)

type
  TestSendComponent[L] = ref object of Component
    msg: int
    sendLink: L

  TestRecvComponent = ref object of Component
    msg: int
    recvPort: Port[int]

#
# Two components communicating
#

component comp, TestSendComponent[Link[int]]:
  startup:
    comp.sendLink.send(comp.msg)

component comp, TestRecvComponent:
  onMessage comp.recvPort, msg:
    comp.msg = msg

test "Two Components communicating":
  let
    sendComp = TestSendComponent[Link[int]](msg: 42)
    recvComp = TestRecvComponent(msg: 0, recvPort: Port[int]())

  var components: seq[Component]

  components.add(sendComp)
  components.add(recvComp)

  var sim = makeTestSim(components)

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

component comp, MultiMessageSend:
  startup:
    for msg in comp.msgs:
      comp.sendLink.send(msg[0], msg[1])

component comp, MultiMessageRecv:
  useSimulator sim
  onMessage comp.recvPort, msg:
    comp.msgs.add (msg, sim.currentTime - 1)

test "Multiple messages different delays":
  let
    sender = MultiMessageSend(
      msgs: @[(1, 0), (2, 5), (3, 25)],
      sendLink: newLink[int](1)
    )
    receiver = MultiMessageRecv(recvPort: newPort[int]())

  var sim = makeTestSim(@[sender, receiver])

  sim.connect(sender, sender.sendLink, receiver, receiver.recvPort)

  sim.run()

  for (smsg, rmsg) in zip(sender.msgs, receiver.msgs):
    check(smsg == rmsg)

#
# Broadcast to component
#

component comp, TestSendComponent[BcastLink[int]]:
  startup:
    comp.sendLink.send(comp.msg)

test "Broadcast to two components":
  let
    sender = TestSendComponent[BcastLink[int]](msg: 42, sendLink: newBcastLink[int](0))
    receivers = [
      TestRecvComponent(msg: 0, recvPort: newPort[int]()),
      TestRecvComponent(msg: 0, recvPort: newPort[int]())
    ]

  var components: seq[Component]

  components.add(sender)
  for receiver in receivers:
    components.add(receiver)

  var
    sim = makeTestSim(components)

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

proc newRandomComponent(total: int, index: int): RandomComponent =
  return RandomComponent(
    input: newPort[int](),
    outs: toSeq(0..<total).map(_ => newLink[int](1)),
  )

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
  let
    count = rand(3..20)
  var
    comps: seq[RandomComponent]

  for i in 0..<count:
    comps.add newRandomComponent(count, i)

  var
    retyped_comps = comps.mapIt(Component(it))
    sim = makeTestSim(retyped_comps)

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
      check(idx >= 0 and idx < comps.len)
      let cidx = comps[idx].received.find msg
      check(cidx != -1)
      comps[idx].received.del cidx

  for comp in comps:
    check(comp.received.len == 0)
