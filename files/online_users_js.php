<?php
/*
 * AloNet copy of admin/report/online_users_js.php (ported from the WANPIRE deployment) (the XML feed of the
 * JavaScript "advanced" Online Users page, online_users.php?js).
 *  - Passes from,to (0,3000) to the paged report.getOnlineUsers; the stock
 *    file passed only 5 args, asked for rows 0..0 and the page was empty.
 *  - Adds <ras_summary>: per-RAS sessions, distinct users, in/out bytes and
 *    rates, always over ALL online users (one extra unfiltered call only
 *    when a RAS/username filter is active), for the "Online Users per RAS"
 *    table in online_users_js.tpl.
 */

require_once("../../inc/init.php");
require_once(IBSINC."report.php");
require_once(IBSINC."xml.php");


needAuthType(ADMIN_AUTH_TYPE);

define("MAX_ONLINES_PER_CALL", 3000);    // XML-RPC max rows per report.getOnlineUsers call

$conds=intGetConditions();
$req=new GetOnlineUsers($_REQUEST["internet_order_by"],
                        $_REQUEST["internet_desc"]=="true",
                        $_REQUEST["voip_order_by"],
                        $_REQUEST["voip_desc"]=="true",
                        $conds,
                        0, MAX_ONLINES_PER_CALL);

$resp=$req->sendAndRecv();
if($resp->isSuccessful())
{
    list($internet_onlines,$voip_onlines)=$resp->getResult();

    // per-RAS summary over everyone online, independent of the list filters
    $all_onlines=$internet_onlines;
    if(count($conds)>0)
    {
        $all_req=new GetOnlineUsers("login_time", FALSE, "login_time", FALSE, array(), 0, MAX_ONLINES_PER_CALL);
        $all_resp=$all_req->sendAndRecv();
        if($all_resp->isSuccessful())
            list($all_onlines,$ignored)=$all_resp->getResult();
    }

    $internet_xml="<internet_onlines>".convAllDicsToXML($internet_onlines,"row")."</internet_onlines>";
    $voip_xml="<voip_onlines>".convAllDicsToXML($voip_onlines,"row")."</voip_onlines>";
    $summary_xml="<ras_summary>".convAllDicsToXML(intRasSummary($all_onlines),"ras")."</ras_summary>";
    print xmlAnswer("onlines",TRUE, $internet_xml.$voip_xml.$summary_xml );
}
else
    print xmlAnswer("onlines",FALSE,"",$resp->getErrorMsg());


function intGetConditions()
{
    $collector=new ReportCollector();
    $collector->addToCondsFromCheckBoxRequest("ras_","ras_ips");
    $collector->addToCondsFromCheckBoxRequest("username_","username_starts_with");
    return $collector->getConds();
}

function intRasSummary(&$onlines)
{
    $by_ras=array();
    $users=array();
    foreach($onlines as $row)
    {
        $ip=$row["ras_ip"];
        if(!isset($by_ras[$ip]))
        {
            $by_ras[$ip]=array("ip"=>$ip, "desc"=>$row["ras_description"], "sessions"=>0, "users"=>0,
                               "in_bytes"=>0, "out_bytes"=>0, "in_rate"=>0, "out_rate"=>0);
            $users[$ip]=array();
        }
        $by_ras[$ip]["sessions"]++;
        $users[$ip][$row["normal_username"]]=1;
        foreach(array("in_bytes","out_bytes","in_rate","out_rate") as $k)
            if(isset($row[$k]) && $row[$k]>0)
                $by_ras[$ip][$k]+=$row[$k];
    }
    foreach($by_ras as $ip=>$r)
        $by_ras[$ip]["users"]=count($users[$ip]);
    return array_values($by_ras);
}

?>
