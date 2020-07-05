## Example for the checkin counter at an airport. There are two lines:
## one for premium passengers and one for everyone else. There are
## several premium stations that will take regular passengers if no
## premium passengers are waiting. Otherwise the regular passengers
## use the regular stations.
##
## SimulationTime is interpreted in seconds for the purpose of this
## simulation.
##

import random/urandom
import random/mersenne
import deques
import heapqueue

import desim
import alea

proc minutes(sec: SimulationTime): SimulationTime =
  60 * sec

proc hours(sec: SimulationTime): SimulationTime =
  60 * minutes sec

const
  simulationDuration = minutes 2
  entranceToLine: SimulationTime = 20
  lineToCounter: SimulationTime = 10

  baseCustomerTime: SimulationTime = 30
  hasBagsTime: SimulationTime = 15
  hasIssuesTime: SimulationTime = minutes 4

#
# Define random number generator
#

var rnd = alea.wrap(initMersenneTwister(urandom(16)))

type

  Customer = object
    ## Define some data for a customer. Here we track whether the
    ## customer is checking in bags and whether they have any
    ## additional issues. These will affect their proccessing time
    ## once at the counter.
    hasBags: bool
    hasIssues: bool

    id: int

    enterSimTime: SimulationTime
    enterLineTime: SimulationTime
    enterCounterTime: SimulationTime
    leaveSimTime: SimulationTime

#
# Define Entrance Component
#

type
  Entrance = ref object of Component
    ## Represent where new customers enter. Customers will never enter
    ## at the same time, but they may be separated by as little as one
    ## second.
    line: Link[Customer]
    arrivalLink: Link[bool]  # The message type is not used
    arrivalPort: Port[bool]

    # Random variables determining the behavior of new customers.
    meanArrival: alea.Poisson
    hasBags: alea.Choice[bool]
    hasIssues: alea.Choice[bool]

    nextCustomerId: int
    shutdownTime: SimulationTime

proc newEntrance(sim: Simulator,
                 meanArrival: Poisson,
                 hasBags: Choice[bool],
                 hasIssues: Choice[bool],
                 shutdownTime: SimulationTime): Entrance =
  ## Create a new Entrance using default latencies.
  result = newComponent[Entrance](sim)
  result.line = newLink[Customer](sim, entranceToLine)
  result.arrivalLink = newLink[bool](sim, 1)
  result.arrivalPort = newPort[bool]()
  result.meanArrival = meanArrival
  result.hasBags = hasBags
  result.hasIssues = hasIssues
  result.shutdownTime = shutdownTime


proc makeCustomer(ent: Entrance, time: Simulationtime): Customer =
  ## Create a new Customer object according to the stored random
  ## variables.
  var
    hasBags = rnd.sample(ent.hasBags)
    hasIssues = rnd.sample(ent.hasIssues)
  result = Customer(hasBags: hasBags,
                    hasIssues: hasIssues,
                    id: ent.nextCustomerId,
                    enterSimTime: time)
  ent.nextCustomerId += 1


proc getNextArrivalTime(ent: Entrance, linkOffset: SimulationTime): SimulationTime =
  ## Return the next arrival time by sampling from the defined
  ## distribution.
  return SimulationTime(rnd.sample(ent.meanArrival))


component comp, Entrance:
  # Indicate that we will refer to the simulator as `sim`
  useSimulator sim

  startup:
    # Queue the first self-message that prompts the Entrance to create
    # more customers.
    sim.connect(comp, comp.arrivalLink, comp, comp.arrivalPort)
    comp.arrivalLink.send true, comp.getNextArrivalTime(comp.arrivalLink.latency)

  onMessage comp.arrivalPort, _:
    # We receive a message whenever a new customer is due to
    # arrive. Create the customer, then figure out when the next one
    # arrives, and reschedule this handler.
    let cust = comp.makeCustomer sim.currentTime
    comp.line.send cust

    # Schedule this message handler again
    if sim.currentTime <= comp.shutdownTime:
      comp.arrivalLink.send true, comp.getNextArrivalTime(comp.arrivalLink.latency)

#
# Define Line component
#

type
  Line = ref object of Component
    ## A holding area for customers until they can be served at the
    ## counter. First come first served.
    customerIn: Port[Customer]
    customerOut: BcastLink[(Customer, int)]
    counterReady: Port[int]

    customers: Deque[Customer]
    readyCounters: seq[int]

proc newLine(sim: Simulator): Line =
  ## Create a new Line with default objects
  result = newComponent[Line](sim)
  result.customerIn = newPort[Customer]()
  result.customerOut = newBcastLink[(Customer, int)](sim, lineToCounter)
  result.counterReady = newPort[int]()
  result.customers = initDeque[Customer]()


proc sendCustomers(line: Line) =
  ## Send the next waiting customer to an available line
  while line.customers.len > 0 and line.readyCounters.len > 0:
    let
      cust = line.customers.popFirst
      counter = line.readyCounters.pop
    line.customerOut.send (cust, counter)

component comp, Line:
  useSimulator sim

  echo "line.customerIn.len: ", comp.customerIn.events.len

  onMessage comp.customerIn, customer:
    var
      customer = customer
    echo "New customer in line"
    customer.enterLineTime = sim.currentTime  
    comp.customers.addLast customer

  onMessage comp.counterReady, counter:
    echo "Counter ", counter, " is ready"
    comp.readyCounters.add counter

  comp.sendCustomers

#
# Define Counter component
#

type
  Counter = ref object of Component
    ## One station at the check-in counter.
    customerIn: Port[(Customer, int)]
    ready: Link[int]

    index: int


proc newCounter(sim: Simulator, index: int): Counter =
  result = newComponent[Counter](sim)
  result.customerIn = newPort[(Customer, int)]()
  result.ready = newLink[int](sim, baseCustomerTime)
  result.index = index


proc calculateExtraWaitTime(customer: Customer): SimulationTime =
  ## Calculate the extra time above base customer processing that must
  ## occur. We break processing time into base and extra so that the
  ## link may have a minimum time, although that is not strictly
  ## necessary.
  var time: Simulationtime = 0
  if customer.hasBags:
    time += hasBagsTime
  if customer.hasIssues:
    time += hasIssuesTime
  return time


proc display(customer: Customer) =
  ## Display a customer's data upon leaving the simulation.
  echo "Customer ", customer.id, " done"
  echo " bags: ", customer.hasBags
  echo " issues: ", customer.hasIssues
  echo " enter time: ", customer.enterSimTime
  echo " line time: ", customer.enterLineTime
  echo " counter time: ", customer.enterCounterTime
  echo " leave time: ", customer.leaveSimTime


component comp, Counter:
  useSimulator sim

  startup:
    comp.ready.send comp.index

  onMessage comp.customerIn, customerPacket:
    # Handle the customer by calculating their wait time and then
    # sending a ready message with that delay.
    var
      (customer, index) = customerPacket
      extra = customer.calculateExtraWaitTime

    if index == comp.index:
      echo "Customer at counter ", comp.index
      customer.enterCounterTime = sim.currentTime
      customer.leaveSimTime = sim.currentTime + comp.ready.latency + extra
      comp.ready.send comp.index, extra
      customer.display

#
# Run Simulation
#

proc main() =
  var
    meanArrival = alea.poisson(10)
    hasBags = alea.choice([true, false, false, false])
    hasIssues = alea.choice([true, false, false, false, false, false])

    sim = newSimulator()
    ent = newEntrance(sim,
                      meanArrival,
                      hasBags,
                      hasIssues,
                      simulationDuration)
    line = newLine(sim)

  sim.connect(ent, ent.line, line, line.customerIn)

  for i in 0..<1:
    var counter = newCounter(sim, i)
    sim.connect(line, line.customerOut, counter, counter.customerIn)
    sim.connect(counter, counter.ready, line, line.counterReady)

  echo "Running simulation"
  sim.run()
  echo "Simulation done"

main()
