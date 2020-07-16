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
import strformat

import desim
import desim/components/logger
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
    arrival: Timer[bool]  # The message type is not used
    logger: Logger

    # Random variables determining the behavior of new customers.
    meanArrival: alea.Poisson
    hasBags: alea.Choice[bool]
    hasIssues: alea.Choice[bool]

    nextCustomerId: int
    shutdownTime: SimulationTime

proc newEntrance(meanArrival: Poisson,
                 hasBags: Choice[bool],
                 hasIssues: Choice[bool],
                 shutdownTime: SimulationTime): Entrance =
  ## Create a new Entrance using default latencies.
  Entrance(name: "entrance",
           line: newLink[Customer](entranceToLine),
           arrival: newTimer[bool](), meanArrival: meanArrival,
           hasBags: hasBags, hasIssues: hasIssues, shutdownTime: shutdownTime)


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


proc getNextArrivalTime(ent: Entrance): SimulationTime =
  ## Return the next arrival time by sampling from the defined
  ## distribution.
  return SimulationTime(rnd.sample(ent.meanArrival) + 1)


component comp, Entrance:

  startup:
    comp.arrival.set true, comp.getNextArrivalTime()

  for _ in messages(comp.arrival):
    # This timer is set for whenever a new customer is due to
    # arrive. Create the customer, then figure out when the next one
    # arrives, and reschedule this handler.
    let cust = comp.makeCustomer simulator.currentTime
    comp.logger.info("new customer",
                     ("hasBags", cust.hasBags),
                     ("hasIssues", cust.hasIssues),
                     ("id", cust.id))
    comp.line.send cust

    # Schedule this timer again
    if simulator.currentTime <= comp.shutdownTime:
      comp.arrival.set true, comp.getNextArrivalTime()

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
    logger: Logger

    customers: Deque[Customer]
    readyCounters: seq[int]

proc newLine(): Line =
  ## Create a new Line with default objects
  Line(name: "line",
       customerIn: newPort[Customer](),
       customerOut: newBcastLink[(Customer, int)](lineToCounter),
       counterReady: newPort[int](),
       customers: initDeque[Customer]())


proc sendCustomers(line: Line) =
  ## Send the next waiting customer to an available line
  while line.customers.len > 0 and line.readyCounters.len > 0:
    let
      cust = line.customers.popFirst
      counter = line.readyCounters.pop
    line.customerOut.send (cust, counter)

component comp, Line:

  comp.logger.debug("Processing line",
                    ("length", comp.customerIn.events.len))

  for customer in messages(comp.customerIn):
    var
      customer = customer
    comp.logger.debug("New customer in line",
                      ("id", customer.id))
    customer.enterLineTime = simulator.currentTime  
    comp.customers.addLast customer

  for counter in messages(comp.counterReady):
    comp.logger.debug("Counter is ready",
                      ("id", counter))
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
    logger: Logger

    index: int


proc newCounter(index: int): Counter =
  Counter(name: fmt"counter {index}",
          customerIn: newPort[(Customer, int)](),
          ready: newLink[int](baseCustomerTime),
          index: index)


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


proc logCustomer(logger: var Logger, customer: Customer) =
  ## Display a customer's data upon leaving the simulation.
  logger.info("Customer done",
              ("id", customer.id),
              ("bags", customer.hasBags),
              ("issues", customer.hasIssues),
              ("enter time", customer.enterSimTime),
              ("line time", customer.enterLineTime),
              ("counter time", customer.enterCounterTime),
              ("leave time", customer.leaveSimTime))

component comp, Counter:

  startup:
    comp.ready.send comp.index

  for customerPacket in messages(comp.customerIn):
    # Handle the customer by calculating their wait time and then
    # sending a ready message with that delay.
    var
      (customer, index) = customerPacket
      extra = customer.calculateExtraWaitTime

    if index == comp.index:
      customer.enterCounterTime = simulator.currentTime
      customer.leaveSimTime = simulator.currentTime + comp.ready.latency + extra
      comp.ready.send comp.index, extra
      logCustomer(comp.logger, customer)

#
# Run Simulation
#

proc main() =
  var
    meanArrival = alea.poisson(10)
    hasBags = alea.choice([true, false, false, false])
    hasIssues = alea.choice([true, false, false, false, false, false])

    sim = newSimulator()
    ent = newEntrance(meanArrival,
                      hasBags,
                      hasIssues,
                      simulationDuration)
    line = newLine()
    logComponent = newLogComponent()
    logBuilder = newLoggerBuilder(logComponent)

  sim.register ent
  sim.register line
  sim.register logComponent

  connect(ent.line, line.customerIn)

  logBuilder.setLevel LogLevel.debug
  logBuilder.attach ent
  logBuilder.attach line

  for i in 0..<1:
    var counter = newCounter(i)
    sim.register counter
    connect(line.customerOut, counter.customerIn)
    connect(counter.ready, line.counterReady)
    logBuilder.attach counter

  echo "Running simulation"
  sim.run()
  echo "Simulation done"

main()
