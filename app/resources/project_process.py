"""One cancellable group; an app crash or exited leader must not leave background writers."""
import os
import signal
import sys
import time
app = os.getppid()
if os.getpgrp() != os.getpid():
    os.setsid()
leader = os.getpid()
if os.fork() == 0:
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2): os.dup2(null, fd)
    if null > 2: os.close(null)
    while os.getppid() == leader:
        try: os.kill(app, 0)
        except ProcessLookupError: break
        time.sleep(0.2)
    try: os.killpg(leader, signal.SIGKILL)
    except ProcessLookupError: pass
    os._exit(0)
os.execvpe(sys.argv[1], sys.argv[1:], os.environ)
