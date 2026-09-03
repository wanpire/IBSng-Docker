#!/usr/bin/env python2
# Patches core/report/report_handler.py's getOnlineUsers() to accept
# "from"/"to" and slice the (already sorted) result before returning it,
# instead of always returning every online session. See README.md for
# why this is needed: with no bound at all, this method's response grows
# without limit as concurrent online users grow, and the admin panel's
# "Online Users" page renders the entire thing in one unpaginated HTML
# table -- which is what actually exhausts PHP's memory_limit, not this
# core method itself (this method stays fast either way; see README).
#
# Replaces the function line-range wholesale (found by matching each
# line with trailing whitespace stripped, since the original file has a
# couple of blank-looking lines that actually carry trailing spaces) so
# this isn't fragile to that kind of incidental formatting. Fails loudly
# if the anchor lines aren't found, so a future IBSng source change that
# no longer matches this exactly is caught at build time instead of
# silently no-op'ing.
import sys

PATH = "/usr/local/IBSng/core/report/report_handler.py"

START_LINE = "    def getOnlineUsers(self,request):"
END_LINE = "        return (normal_onlines, voip_onlines)"

NEW_LINES = '''    def getOnlineUsers(self,request):
        request.needAuthType(request.ADMIN)
        request.checkArgs("normal_sort_by", "normal_desc", "voip_sort_by", "voip_desc", "conds", "from", "to")
        requester=request.getAuthNameObj()
        if requester.hasPerm("SEE ONLINE USERS"):
            admin_perm_obj=requester.getPerms()["SEE ONLINE USERS"]
        elif requester.isGod():
            admin_perm_obj=None
        else:
            raise GeneralException(errorText("GENERAL","ACCESS_DENIED"))

        filter_manager = onlines_filter.createFilterManager(report_lib.fixConditionsDic(request["conds"]))

        normal_onlines, voip_onlines = online.getFormattedOnlineUsers(request.getDateType(), filter_manager)
        normal_onlines, voip_onlines = online.sortOnlineUsers(normal_onlines, voip_onlines,
                                       (request["normal_sort_by"], request["normal_desc"]),
                                       (request["voip_sort_by"], request["voip_desc"]))

        if admin_perm_obj!=None and admin_perm_obj.isRestricted():
            normal_onlines=filter(lambda online_dic:online_dic["owner_id"]==requester.getAdminID(),normal_onlines)
            voip_onlines=filter(lambda online_dic:online_dic["owner_id"]==requester.getAdminID(),voip_onlines)

        # Pagination: bound how many rows we ever hand back over XML-RPC.
        # Sorting already happened above, so slicing here still returns
        # the correct "top N by current sort order" page. See README for
        # why this exists: an admin panel page rendering this response
        # in one unpaginated HTML table is what runs PHP out of memory
        # once online count gets large -- bounding the response here
        # bounds that render, regardless of true online count.
        normal_total=len(normal_onlines)
        voip_total=len(voip_onlines)
        report_lib.checkFromTo(request["from"],request["to"])
        _from=request["from"]
        _to=request["to"]

        return (normal_onlines[_from:_to], voip_onlines[_from:_to], normal_total, voip_total)
'''.split("\n")
if NEW_LINES and NEW_LINES[-1] == "":
    NEW_LINES.pop()

with open(PATH) as f:
    lines = f.read().split("\n")

start_idx = None
end_idx = None
for i, line in enumerate(lines):
    if line.rstrip() == START_LINE:
        start_idx = i
    elif start_idx is not None and end_idx is None and line.rstrip() == END_LINE:
        end_idx = i
        break

if start_idx is None or end_idx is None:
    sys.stderr.write("paginate_online_users.py: could not find getOnlineUsers() start/end anchor "
                      "lines in %s -- IBSng source has changed in a way this patch doesn't expect, "
                      "refusing to silently no-op.\n" % PATH)
    sys.exit(1)

new_content_lines = lines[:start_idx] + NEW_LINES + lines[end_idx + 1:]

with open(PATH, "w") as f:
    f.write("\n".join(new_content_lines))

print "paginate_online_users.py: patched %s (lines %d-%d replaced)" % (PATH, start_idx + 1, end_idx + 1)
