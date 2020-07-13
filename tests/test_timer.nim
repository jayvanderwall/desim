import unittest

import desim
import random
import sugar
import seqUtils

randomize()

type

  TestComponent = ref object of Component
    selfTimer: Timer[int]
    toSend: seq[(int, SimulationTime)]
    received: seq[(int, SimulationTime)]


proc newTestComponent(events: seq[(int, SimulationTime)]): TestComponent =
  TestComponent(selfTimer: newTimer[int](), toSend: events)


component comp, TestComponent:

  startup:
    for msg in comp.toSend:
      comp.selfTimer.set msg[0], msg[1]

  for msg in messages(comp.selfTimer):
    comp.received.add (msg, simulator.currentTime)


test "Set timers":
  let
    count = rand(1..20)
    events = toSeq(1..count).map(_ => (rand(-100..100), rand(1..100)))

  var
    sim = newSimulator()
    comp = newTestComponent(events)

  sim.register comp

  sim.run()

  for i in 1..<comp.received.len:
    check(comp.received[i][1] >= comp.received[i - 1][1])

  for event in comp.toSend:
    let idx = comp.received.find event
    check(idx != -1)
    comp.received.del idx

  check(comp.received.len == 0)
