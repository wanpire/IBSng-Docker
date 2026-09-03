#!/usr/bin/env python2
# Companion to paginate_online_users.py: updates the PHP caller
# (admin/report/online_users_funcs.php) to actually use the from/to that
# ReportHelper was already computing and discarding (getFrom()/getTo()
# were dead code before this patch -- everything else on this page only
# ever read getOrderBy()/getDesc() from it), pass them to the now-paged
# core method, and assign the real totals to Smarty so the template can
# render a page-nav widget instead of every row unconditionally.
import sys

PATH = "/usr/local/IBSng/interface/IBSng/admin/report/online_users_funcs.php"

START_LINE = "function intGetOnlineUsers(&$smarty)"
# NOT a bare "}" -- the function body has a nested else { ... } block, so
# searching for the first standalone "}" after START_LINE would match
# that inner brace instead of the function's own closing brace. This
# return statement is unique and always the last real statement in the
# function; its closing "}" is exactly the following line.
RETURN_LINE = "    return array($internet_onlines, $voip_onlines);"

NEW_LINES = '''function intGetOnlineUsers(&$smarty)
{
    // ReportHelper only reads page/rpp from the request when BOTH are
    // present (isInRequest requires every argument given, and nothing
    // ever seeds "rpp" -- {reportPages}'s own generated links don't add
    // it either, they just carry forward whatever's already in
    // $_REQUEST). Without this, clicking a page-2 link would silently
    // do nothing: isInRequest("page","rpp") stays false forever and
    // ReportHelper keeps using its constructor defaults regardless of
    // ?page=N in the URL. Seeding a default here, once, up front makes
    // it "sticky" in $_REQUEST for every link this request's own
    // {reportPages} call generates from here on.
    if(!isInRequest("rpp"))
        $_REQUEST["rpp"]=100;
    // 100 rows/page by default -- overridable per the normal ReportHelper
    // convention (?page=N&rpp=N in the URL), same as every other paged
    // report in this admin panel.
    $report_helper=new ReportHelper(0,100);
    $internet_order_by = $report_helper->getOrderBy();
    $internet_desc = $report_helper->getDesc();
    $from = $report_helper->getFrom();
    $to = $report_helper->getTo();

    $report_helper->order_by_key="voip_order_by";
    $report_helper->desc_key="voip_desc";
    $report_helper->updateToRequest();

    $voip_order_by = $report_helper->getOrderBy();
    $voip_desc = $report_helper->getDesc();

    $req=new GetOnlineUsers($internet_order_by,$internet_desc,$voip_order_by,$voip_desc, array(), $from, $to);
    $resp=$req->sendAndRecv();
    if($resp->isSuccessful())
        list($internet_onlines,$voip_onlines,$internet_total,$voip_total)=$resp->getResult();
    else
    {
        $resp->setErrorInSmarty($smarty);
        $internet_onlines=array();
        $voip_onlines=array();
        $internet_total=0;
        $voip_total=0;
    }
    $smarty->assign("internet_onlines_total",$internet_total);
    $smarty->assign("voip_onlines_total",$voip_total);
    return array($internet_onlines, $voip_onlines);
}
'''.split("\n")
if NEW_LINES and NEW_LINES[-1] == "":
    NEW_LINES.pop()

with open(PATH) as f:
    lines = f.read().split("\n")

start_idx = None
return_idx = None
for i, line in enumerate(lines):
    if line.rstrip() == START_LINE:
        start_idx = i
    elif start_idx is not None and return_idx is None and line.rstrip() == RETURN_LINE:
        return_idx = i
        break

if start_idx is None or return_idx is None:
    sys.stderr.write("paginate_online_users_funcs.py: could not find intGetOnlineUsers() start/return "
                      "anchor lines in %s -- refusing to silently no-op.\n" % PATH)
    sys.exit(1)

end_idx = return_idx + 1  # the function's closing "}", one line after its return statement
if lines[end_idx].rstrip() != "}":
    sys.stderr.write("paginate_online_users_funcs.py: expected '}' right after the return statement "
                      "in %s, found %r instead -- refusing to silently no-op.\n" % (PATH, lines[end_idx]))
    sys.exit(1)

new_content_lines = lines[:start_idx] + NEW_LINES + lines[end_idx + 1:]

with open(PATH, "w") as f:
    f.write("\n".join(new_content_lines))

print "paginate_online_users_funcs.py: patched %s (lines %d-%d replaced)" % (PATH, start_idx + 1, end_idx + 1)
