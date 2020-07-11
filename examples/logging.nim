## Example of using logging in nim

import desim
import desim/components/logger
import re

type
  ExampleComponent = ref object of Component
    logger: Logger


proc newExampleComponent(name: string): ExampleComponent =
  ExampleComponent(name: name)


component comp, ExampleComponent:
  startup:
    comp.logger.error("Log Test", ("data", 42), ("escape", "\t\x12\n\""), ("good?", true))

proc main() =

  var
    sim = newSimulator()
    logcomp = newLogComponent()
    comp = newExampleComponent("example")
    logbuilder = newLoggerBuilder(logcomp)

  logbuilder.enableNameRegex re"ex.*"
  logbuilder.attach comp
  
  sim.register comp
  sim.register logcomp

  sim.run

main()
