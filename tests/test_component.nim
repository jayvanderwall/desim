import unittest

import desim

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

component comp, TestSendComponent[Link[int]]:
  startup:
    comp.sendLink.send(comp.msg)

component comp, TestRecvComponent:
  echo "In TestRecvComponent"
  onMessage recvPort, msg:
    comp.msg = msg
  echo "Done TestRecvComponent"

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
