# Runs inside an ibsng-local image (network none) from /usr/local/IBSng against the real IBSng
# core modules (RasMsg, IBSException). Usage: python2.7 test_mikrotik_stop.py <path/to/mikrotik.py>
# Stop packets without Acct-Terminate-Cause (seen live 2026-09-28 08:02, Farzanegan-Prime).
import sys, imp, new, __builtin__
sys.path[0:0] = ["."]
from core import defs
__builtin__.defs = defs
from core.ras.msgs import RasMsg
from core import ibs_exceptions
from core.ibs_exceptions import IBSException
class _Log(object):   # the daemon opens this at startup; IBSException logs through it
    def write(self, *a): pass
ibs_exceptions.error_log_handle = _Log()
mk = imp.load_source("mikrotik_under_test", sys.argv[1])
ok = lambda c, m: sys.stdout.write(("PASS " if c else "FAIL ") + m + "\n")

class Pkt(dict): pass
def ras():
    r = new.instance(mk.MikrotikRas)   # old-style class; skips __init__: no DB, SNMP or SSH
    r.inouts, r.onlines, r.logs = {"7": {"in_bytes": 0, "out_bytes": 0}}, {}, []
    r.toLog = lambda *a: r.logs.append(a)
    return r
def stop(**extra):
    p = Pkt({"Acct-Status-Type": ["Stop"], "NAS-Port": [7], "User-Name": ["alo.vc2eme"],
             "Framed-IP-Address": ["10.0.0.5"], "Acct-Session-Id": ["81a00001"],
             "Acct-Output-Octets": [26000000], "Acct-Input-Octets": [900000]})
    p.update(extra)
    return p
def run(pkt):
    r = ras(); m = RasMsg(pkt, None, r)
    try: r.handleRadAcctPacket(m); return r, m, None
    except IBSException, e: return r, m, e

r, m, e = run(stop())
ok(e is None and m.getAction() == "INTERNET_STOP", "1 Stop without Acct-Terminate-Cause -> INTERNET_STOP, no exception (%s)" % e)
ok(not m.hasAttr("terminate_cause") and m["in_bytes"] == 26000000 and r.inouts["7"]["in_bytes"] == 26000000,
   "2 no terminate_cause attr; bytes still read and cached")
r, m, e = run(stop(**{"Acct-Terminate-Cause": ["User-Request"]}))
ok(e is None and m["terminate_cause"] == "User-Request", "3 Stop with Acct-Terminate-Cause -> copied as before")
p = stop(); del p["Acct-Session-Id"]
r, m, e = run(p)
ok(e is not None and "Acct-Session-Id" in str(e), "4 other Stop attrs still required (missing Acct-Session-Id raises: %s)" % e)
