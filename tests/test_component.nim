import unittest

import desim

type
  TestSelfComponent = ref object of Component
    counter: int
    selfLink: Link

method receiveSelf(comp: TestSelfComponent, msg: Message) {.base.} =
  comp.counter += 1

method start(comp: TestSelfComponent) =
  comp.sim.connect(comp, selfLink, comp, receiveSelf)
  comp.selfLink.send(Message())

proc makeTestSim(components: seq[Component]): Simulator =
  result = newSimulator()
  for comp in components:
    result.register(comp)

test "Component with self loop":

  let
    testComp = TestSelfComponent()
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

  TestMessage = ref object of Message
    msg: int

method receiveMessage(comp: TestRecvComponent, msg: Message) {.base.} =
  raise newException(Exception, "Bad message")

method receiveMessage(comp: TestRecvComponent, msg: TestMessage) =
  comp.msg = msg.msg

method start(comp: TestSendComponent[Link]) =
  comp.sendLink.send(TestMessage(msg: comp.msg))

method start(comp: TestSendComponent[BcastLink]) =
  comp.sendLink.send(TestMessage(msg: comp.msg))

test "Two Components communicating":
  let
    sendComp = TestSendComponent[Link](msg: 42)
    recvComp = TestRecvComponent(msg: 0)

  var components: seq[Component]

  components.add(sendComp)
  components.add(recvComp)

  var sim = makeTestSim(components)

  sim.connect(sendComp, sendLink, recvComp, receiveMessage)

  sim.run()

  check(recvComp.msg == sendComp.msg)

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
