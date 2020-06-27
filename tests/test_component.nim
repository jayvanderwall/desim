import unittest

import desim
import sequtils

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

  onMessage selfPort, msg:
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
  onMessage recvPort, msg:
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
  onMessage recvPort, msg:
    echo "Got message ", msg, " at time ", sim.currentTime
    comp.msgs.add (msg, sim.currentTime)

test "Multiple messages different delays":
  let
    sender = MultiMessageSend(
      msgs: @[(1, 0), (2, 5), (3, 25)],
      sendLink: newLink[int](0)
    )
    receiver = MultiMessageRecv(recvPort: newPort[int]())

  var sim = makeTestSim(@[sender, receiver])

  sim.connect(sender, sender.sendLink, receiver, receiver.recvPort)

  sim.run()

  for (smsg, rmsg) in zip(sender.msgs, receiver.msgs):
    check(smsg == rmsg)

#[
test "Broadcast to two components":
  let
    sender = TestSendComponent[BcastLink](msg: 42)
    receivers = [
      TestRecvComponent(msg: 0),
      TestRecvComponent(msg: 0)
    ]

  var components: seq[Component]

  components.add(sender)
  for receiver in receivers:
    components.add(receiver)

  var
    sim = makeTestSim(components)

  for receiver in receivers:
    sim.connect(sender, sendLink, receiver, receiveMessage)

  sim.run()

  for idx, receiver in receivers:
    check(receiver.msg == sender.msg)
]#
