import unittest

import desim
import desim/components/logger
import options

type

  TestComponent = ref object of Component
    logger: Logger
    msg: string

proc newTestComponent(name: string, msg: string): TestComponent =
  TestComponent(name: name, msg: msg)


component comp, TestComponent:
  startup:
    comp.logger.info(comp.msg)


proc main() =
  test "Create logger":

    var
      actMsg: string

    proc logwrite (msg: LogMessage) =
      # "msg" is one of the guaranteed fields, along with "level" and "time".
      actMsg = msg.find("msg").get()

    var
      sim = newSimulator()
      logcomp = newLogComponent(write=logwrite)
      comp = newTestComponent("test", "test_message")
      logbuilder = newLoggerBuilder(logcomp)

    logbuilder.attach comp

    sim.register comp
    sim.register logcomp

    sim.run()

    check(actMsg == comp.msg)

# Putting the tests inside main stops the compiler from complaining
# about the logwrite closure.
main()
