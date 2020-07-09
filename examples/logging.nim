## Example of using logging in nim

import desim
import desim/components/logger
import re

type
  ExampleComponent = ref object of Component
    logger: Logger


proc newExampleComponent(logbuilder: LoggerBuilder, name: string): ExampleComponent =
  ExampleComponent(logger: logbuilder.build(name))


component comp, ExampleComponent:
  startup:
    comp.logger.error("Log Test")

proc main() =

  var
    sim = newSimulator()
    logcomp = newLogComponent()

  var
    logbuilder = newLoggerBuilder(logcomp)

  logbuilder.disableNameRegex re"abc.*"

  var
    comp = newExampleComponent(logbuilder, "example")

  sim.register comp
  sim.register logcomp

  connect(comp.logger.link, logcomp.port)

  sim.run

main()
