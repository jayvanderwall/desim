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


proc newTestComponent(sim: Simulator,
                      events: seq[(int, SimulationTime)]): TestComponent =
  result = newComponent[TestComponent](sim)
  result.selfTimer = newTimer[int](sim)
  result.toSend = events


component comp, TestComponent:
  useSimulator sim

  startup:
    for msg in comp.toSend:
      comp.selfTimer.set msg[0], msg[1]

  onTimer comp.selfTimer, msg:
    comp.received.add (msg, sim.currentTime)


test "Set timers":
  let
    count = rand(1..20)
    events = toSeq(1..count).map(_ => (rand(-100..100), rand(1..100)))

  var
    sim = newSimulator()
    comp = newTestComponent(sim, events)

  sim.run()

  for i in 1..<comp.received.len:
    check(comp.received[i][1] >= comp.received[i - 1][1])

  for event in comp.toSend:
    let idx = comp.received.find event
    check(idx != -1)
    comp.received.del idx

  check(comp.received.len == 0)
