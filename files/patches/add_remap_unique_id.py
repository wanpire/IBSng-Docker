#!/usr/bin/env python2
# Adds OnlineUsers.remapUniqueId() to core/user/online.py -- lets a RAS
# type update the unique id (e.g. NAS-Port) an already-online instance is
# tracked under, without a logout/login cycle. Needed for RAS types whose
# per-session identifier can change mid-session (e.g. ocserv reassigning
# NAS-Port on each interim accounting update) while the underlying
# connection and its cumulative accounting totals continue uninterrupted.
# See core/ras/rases/pppd.py's __remapStalePortForUser, the only current
# caller, for the full rationale (confirmed via packet capture: a single
# real ocserv session reported a steadily growing NAS-Port alongside
# continuously increasing byte counts and session time -- treating each
# port change as a real reconnect was wrong, and reset session duration
# and discarded/duplicated billed usage on every cycle).
#
# Inserted immediately before killUser(), found by exact match on its def
# line -- stable across the file regardless of exactly what clearUser()
# above it looks like line-by-line. Fails loudly if that anchor isn't
# found, so a future IBSng source change that no longer matches is caught
# at build time instead of silently no-op'ing.
import sys

PATH = "/usr/local/IBSng/core/user/online.py"

ANCHOR = "    def killUser(self,user_id, ras_id, unique_id, kill_reason):"

NEW_METHOD = '''    def remapUniqueId(self, user_id, ras_id, old_unique_id, new_unique_id):
        """
            Update the unique id (e.g. NAS-Port) under which an already-online
            instance is tracked, without a logout/login cycle. Needed for RAS
            types whose per-session identifier can change mid-session (e.g.
            ocserv reassigning NAS-Port on each interim accounting update)
            while the underlying connection and its cumulative accounting
            totals continue uninterrupted. Returns True if the remap
            succeeded, False if there was nothing online under old_unique_id
            to remap (caller should fall back to a normal re-online).
        """
        self.loading_user.loadingStart(user_id)
        try:
            user_obj = self.getUserObjByUniqueID(ras_id, old_unique_id)
            if user_obj == None or user_obj.getUserID() != user_id:
                return False

            instance = user_obj.getInstanceFromUniqueID(ras_id, old_unique_id)
            if instance == None:
                return False

            instance_info = user_obj.getInstanceInfo(instance)
            instance_info["unique_id_val"] = new_unique_id
            unique_id_name = instance_info["unique_id"]
            if instance_info["attrs"].has_key(unique_id_name):
                instance_info["attrs"][unique_id_name] = new_unique_id

            old_key = (ras_id, old_unique_id)
            new_key = (ras_id, new_unique_id)
            if self.ras_onlines.has_key(old_key):
                del self.ras_onlines[old_key]
            self.ras_onlines[new_key] = user_obj

            return True
        finally:
            self.loading_user.loadingEnd(user_id)


'''

with open(PATH) as f:
    src = f.read()

assert src.count(ANCHOR) == 1, "anchor not found (or not unique) in %s" % PATH
src = src.replace(ANCHOR, NEW_METHOD + ANCHOR, 1)

with open(PATH, "w") as f:
    f.write(src)

print "OK: remapUniqueId inserted into %s" % PATH
