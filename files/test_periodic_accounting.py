# Runs inside an ibsng-local image (network none) from /usr/local/IBSng against the real IBSng
# core modules. Ported from the WANPIRE deployment (tests 1-8; its permission test is not part of AloNet).
import sys, time
sys.path[0:0] = [".", "core/user/plugins"]
from core.user import user_main
class _AL(object): AUDIT_LOG_NOVALUE = "NOVALUE"
user_main.getUserAuditLogManager = lambda: _AL()
import periodic_accounting as pa
Q = []
class AM(object):
    def insertUserAttrQuery(self, uid, name, val): Q.append(("INSERT", name, long(val))); return "I;"
    def updateUserAttrQuery(self, uid, name, val): Q.append(("UPDATE", name, long(val))); return "U;"
user_main.getActionManager = lambda: AM()
class Attrs(object):
    def __init__(self, group, user): self.g = group; self.u = user
    def hasAttr(self, k): return k in self.u or k in self.g
    def userHasAttr(self, k): return k in self.u
    def __getitem__(self, k): return self.u[k] if k in self.u else self.g[k]
class Loaded(object):
    def __init__(self, a): self.a = a
    def hasAttr(self, k): return self.a.hasAttr(k)
class TypeObj(object):
    def __init__(self): self.bytes = {1: (1000, 500)}
    def getInOutBytes(self, inst): return self.bytes[inst] + (0, 0)
class User(object):
    def __init__(self, attrs):
        self.attrs = attrs; self.instances = 0; self.t = TypeObj(); self.info = []
    def getUserAttrs(self): return self.attrs
    def getLoadedUser(self): return Loaded(self.attrs)
    def isNormalUser(self): return True
    def getTypeObj(self): return self.t
    def getUserID(self): return 35954
    def getInstanceInfo(self, i): return self.info[i - 1]
K = "traffic_periodic_accounting_monthly"
JAL = {K: "jalali", K + "_limit": "107374182400"}
GRE = {K: "gregorian", K + "_limit": "107374182400"}
ROWS = {K + "_usage": "2641248264", K + "_reset": "1792701000"}
class RasMsg(dict):
    def hasAttr(self, k): return k in self
ok = lambda c, m: sys.stdout.write(("PASS " if c else "FAIL ") + m + "\n")

# pr.c41 scenario: online on a jalali group, admin moves it to a gregorian group, then logout
u = User(Attrs(JAL, dict(ROWS))); p = pa.MonthlyTrafficPeriodicAccounting(u)
ok(p.first_login is False and p.initial_usage == 2641248264, "1 login: existing rows seen, first_login False")
u.instances = 1; p.s_login(RasMsg(start_accounting=True))
u.attrs = Attrs(GRE, dict(ROWS)); p._reload()
ok(p.first_login is False and p.next_reset == 1792701000 and p.initial_usage == 2641248264 and p.value == "gregorian",
   "2 group change jalali->gregorian while online: period+usage kept, first_login stays False")
u.t.bytes[1] = (4000, 2000); u.info = [{"logout_ras_msg": 1}]
del Q[:]; p.s_commit()
ok(Q and all(q[0] == "UPDATE" for q in Q) and Q[0] == ("UPDATE", K + "_usage", 2641248264 + 4500), "3 logout commits UPDATE (no duplicate-key INSERT), usage = stored + session: %s" % Q)
# defence in depth: first_login True but rows exist -> still UPDATE
u2 = User(Attrs(GRE, dict(ROWS))); p2 = pa.MonthlyTrafficPeriodicAccounting(u2); p2.first_login = True; p2.commit_next_reset = True
u2.instances = 1; u2.info = [{"logout_ras_msg": 1}]; p2.instance_start_value = [0]
del Q[:]; p2.s_commit(); ok([q[0] for q in Q] == ["UPDATE", "UPDATE"], "4 first_login=True with existing rows -> UPDATE both: %s" % Q)
# brand-new user without rows -> INSERT (stock behaviour kept)
u3 = User(Attrs(GRE, {})); p3 = pa.MonthlyTrafficPeriodicAccounting(u3); u3.instances = 1; p3.s_login(RasMsg(start_accounting=True)); u3.info = [{"logout_ras_msg": 1}]
del Q[:]; p3.s_commit(); ok([q[0] for q in Q] == ["INSERT", "INSERT"], "5 user without rows -> INSERT both (unchanged): %s" % Q)
# lost start value (the stuck state): no IndexError anywhere
class _R(object):
    def getAssumedKPS(self): return 100
class _CI(object): effective_rules = [_R()]
u4 = User(Attrs(GRE, dict(ROWS))); u4.charge_info = _CI(); p4 = pa.MonthlyTrafficPeriodicAccounting(u4); u4.instances = 1; p4.instance_start_value = []
try:
    x = p4._calcUsage(); p4.s_canStayOnline(); ok(x == 2641248264, "6 instance with no start value: _calcUsage/canStayOnline OK (usage %d), no IndexError" % x)
except Exception, e: ok(False, "6 raised %r" % e)
p4._setStartValues(); ok(len(p4.instance_start_value) == 1, "7 _setStartValues pads the list")
p4.instance_start_value = []; p4.s_update(RasMsg(start_accounting=True)) if False else None
# unchanged value reload still refreshes initial usage (e.g. usage reset by an admin while online)
u5 = User(Attrs(GRE, dict(ROWS))); p5 = pa.MonthlyTrafficPeriodicAccounting(u5)
u5.attrs = Attrs(GRE, dict(ROWS, **{K + "_usage": "0"})); p5._reload(); ok(p5.initial_usage == 0, "8 admin resets usage of an online user -> initial_usage refreshed to 0")
