{* Online Users By Type : Show a list of online users, seperated by their type(eg. Internet or VoIP)
   AloNet copy (ported from the WANPIRE deployment): adds the "Online Users per RAS" summary table (click a RAS to show only it) and
   makes RAS/username filter changes refresh immediately instead of at the next timer tick.
*}

{include file="admin_header.tpl" title="Online Users" selected="Online Users" page_valign=top} 

<script language="javascript" src="/IBSng/js/check_box_container.js"></script>
<script type="text/javascript" src="/IBSng/js/onlines.js"></script>
<script type="text/javascript" src="/IBSng/js/libface.js"></script>

<table align=center border=0 style="display: none" id="error_table"> 
<tr> 
<td align=left>
    <img border="0" src="/IBSng/images/msg/before_error_message.gif">
</td>
    <td align=left class="error_messages">
	<span id="error_message">&nbsp;</span>
    </td>
</tr>
</table>

<div align=center><a href="online_users.php" class="page_menu" style="font-weight: bold; font-size: 11; font-family: tahoma;">Switch to Normal Mode</a></div>
<br>

<!-- kill user frame -->
<iframe name=msg id=msg border=0 FRAMEBORDER=0 SCROLLING=NO height=50 valign=top src="/IBSng/util/empty.php"></iframe>

{tabTable tabs="Ras Filter,Internet,VoIP,Username Filter" content_height=50 action_icon="" form_name=""}
    {tabContent tab_name="Ras Filter" add_table_tag=TRUE add_table_id="ras_filter_select"}
	{include file="admin/report/online_users/ras_filter.tpl"} 
    {/tabContent}

    {tabContent tab_name="Username Filter" add_table_tag=TRUE add_table_id="username_filter_select"}
	{include file="admin/report/online_users/username_filter.tpl"} 
    {/tabContent}

    {tabContent tab_name="Internet" add_table_tag=TRUE add_table_id="internet_select"}
	{include file="admin/report/online_users/internet_attrs.tpl"} 
    {/tabContent}

    {tabContent tab_name="VoIP" add_table_tag=TRUE add_table_id="voip_select"}
	{include file="admin/report/online_users/voip_attrs.tpl"} 
    {/tabContent}

    <tr><td colspan=20 align=center>	

    <table width=100% border="0" cellspacing="0" bordercolor="#000000" cellpadding="0">    

	<tr class="List_Foot_Line_red">
		<td colspan=30></td>
	</tr>

	{include file="admin/report/online_users/tab_foot.tpl"} 

    </table>

    </td></tr>


{/tabTable}

<span id="ras_summary"></span>
<br />

<span id="all_internet">

<form id="internet_onlines" name="internet_onlines"></form>

</span>

<br />

<span id="all_voip">

<form id="voip_onlines" name="voip_onlines"></form>

</span>

<br />

<input align=center type=image src="/IBSng/images/icon/kick.gif" name=kick value="kick" onClick="actionIconClicked('kick')">
<input align=center type=image src="/IBSng/images/icon/clear.gif" name=clear value="clear" onClick="actionIconClicked('clear')">
<input align=center type=image src="/IBSng/images/icon/message.gif" name=clear value="message" onClick="actionIconClicked('message')">

{literal}
<script>
setCheckBoxesOnclick("internet_select",displayOnlines);
setCheckBoxesOnclick("voip_select",displayOnlines);
wpHookFilters("ras_filter_select");
wpHookFilters("username_filter_select");

window.internet_onlines=[];
window.voip_onlines=[];

window.refresh_timer_status="play";
requestOnlines();


// RAS/username filter changes refresh right away (next 1s timer tick)
function wpHookFilters(id)
{
    var objs=getChildCheckBoxItems(id);
    for(var i in objs)
    {
	var prev=objs[i].onclick;
	objs[i].onclick=(function(p){ return function(e){ if(p) p.call(this,e); window.do_refresh=true; }; })(prev);
    }
}

// show only one RAS (ip), or all RAS (ip == null), and refresh now
function wpSelectRas(ip)
{
    var objs=getChildCheckBoxItems("ras_filter_select");
    for(var i in objs)
	objs[i].checked = (ip != null && objs[i].value == ip);
    window.do_refresh=true;
}

function wpFmtBytes(b)
{
    var units=["B","K","M","G","T"];
    var i=0;
    b=parseFloat(b) || 0;
    while(b>=1024 && i<units.length-1) { b/=1024; i++; }
    return (i>0 && b<10 ? b.toFixed(1) : String(Math.round(b)))+units[i];
}

// "Online Users per RAS" table from <ras_summary> (always all RAS, independent of filters)
function wpRenderRasSummary(xml)
{
    var rows=[];
    var nodes=xml.getElementsByTagName("ras");
    for(var i=0; i<nodes.length; i++)
    {
	var r={};
	for(var c=nodes[i].firstChild; c; c=c.nextSibling)
	    if(c.nodeType==1)
		r[c.nodeName]=(c.textContent !== undefined ? c.textContent : c.text);
	rows.push(r);
    }
    rows.sort(function(a,b){ return parseInt(b.sessions)-parseInt(a.sessions); });

    var selected={};
    var objs=getChildCheckBoxItems("ras_filter_select", true);
    for(var i in objs)
	selected[objs[i].value]=true;

    var lt=new ListTable();
    var cols=["RAS","IP","Sessions","Users","In Rate","Out Rate","In Total","Out Total"];
    var tds="";
    for(var i=0; i<cols.length; i++)
	tds+=lt.createTD(cols[i]);
    var body=lt.createHeaderTR(tds);

    var t={sessions:0, users:0, in_rate:0, out_rate:0, in_bytes:0, out_bytes:0};
    for(var i=0; i<rows.length; i++)
    {
	var r=rows[i];
	for(var k in t)
	    t[k]+=parseFloat(r[k]) || 0;
	var name=(selected[r.ip] ? "<b>&#9658; "+r.desc+"</b>" : r.desc);
	body+='<tr class="List_Row_'+getTRColor(true)+'Color" style="cursor: pointer;" title="Show only '+r.desc+'" '+
	      'onClick="wpSelectRas(\''+r.ip+'\')">'+
	      lt.createTD(name)+lt.createTD(r.ip)+lt.createTD(r.sessions)+lt.createTD(r.users)+
	      lt.createTD(wpFmtBytes(r.in_rate)+"/s")+lt.createTD(wpFmtBytes(r.out_rate)+"/s")+
	      lt.createTD(wpFmtBytes(r.in_bytes))+lt.createTD(wpFmtBytes(r.out_bytes))+'</tr>';
    }
    body+='<tr class="List_Head">'+lt.createTD("<b>Total ("+rows.length+" RAS)</b>")+lt.createTD("")+
	  lt.createTD("<b>"+t.sessions+"</b>")+lt.createTD("<b>"+t.users+"</b>")+
	  lt.createTD("<b>"+wpFmtBytes(t.in_rate)+"/s</b>")+lt.createTD("<b>"+wpFmtBytes(t.out_rate)+"/s</b>")+
	  lt.createTD("<b>"+wpFmtBytes(t.in_bytes)+"</b>")+lt.createTD("<b>"+wpFmtBytes(t.out_bytes)+"</b>")+'</tr>';

    document.getElementById("ras_summary").innerHTML=
	'<div align=center>'+lt.createTable("Online Users per RAS", cols.length, body)+
	'<a href="#" class="link_in_body" onClick="wpSelectRas(null); return false;">Show all RAS</a>'+
	' <font size=1>(click a RAS to show only its users; Users = distinct usernames)</font></div>';
}

function doRequest()
{
    requestOnlines();
}

function getOnlinesHandler(http_request)
{
    if (http_request.readyState == 4) 
    {    
	if (http_request.status == 200) 
	{
	    document.getElementById("request_time").innerHTML=(new Date().getTime() - window.request_send)/1000
	    
    	    clearError();

	    if(http_request.responseXML.getElementsByTagName("result")[0].childNodes[0].nodeValue!="SUCCESS")
		showError(http_request.responseXML.getElementsByTagName("reason")[0].childNodes[0].nodeValue);
	    else
	    {
		var parser_start=new Date().getTime();

	        var xml_internet_onlines=http_request.responseXML.getElementsByTagName("internet_onlines");
		var xml_voip_onlines=http_request.responseXML.getElementsByTagName("voip_onlines");
	        window.internet_onlines=convertOnlinesToArray(xml_internet_onlines[0].childNodes);
		window.voip_onlines=convertOnlinesToArray(xml_voip_onlines[0].childNodes);

		document.getElementById("parser_time").innerHTML=(new Date().getTime() - parser_start)/1000
		
		var render_start=new Date().getTime();
		
		displayOnlines();
		var xml_ras_summary=http_request.responseXML.getElementsByTagName("ras_summary");
		if(xml_ras_summary.length)
		    wpRenderRasSummary(xml_ras_summary[0]);
		
		document.getElementById("render_time").innerHTML=(new Date().getTime() - render_start)/1000
	    }
	    
	}
	else
	    showError("Internal Error");
	
	updateTimer();

    }

}


function requestOnlines()
{
    var http_request;
    changeTimerState("_Loading_");
    
    if (window.XMLHttpRequest)
	http_request = new XMLHttpRequest();
    else if (window.ActiveXObject) 
	http_request = new ActiveXObject("Microsoft.XMLHTTP");

    if(http_request)
    {
	window.request_send=new Date().getTime();
	http_request.onreadystatechange = function() { getOnlinesHandler(http_request) };
	var url='/IBSng/admin/report/online_users_js.php?internet_order_by='+getCurSort("internet")+
							'&internet_desc='+getCurDesc("internet")+
							'&voip_order_by='+getCurSort("voip")+
							"&voip_desc="+getCurDesc("voip")+
							"&"+getFiltersURL();
	http_request.open('GET', url, true);
	http_request.send(null);	
    }
    else
	showError("Browser doesn't support xmlhttp");
}



</script>

{/literal}

<br />
<p align=right style="font-family: tahoma; font-size:6pt"> Request: <span id=request_time></span> Parser: <span id=parser_time></span> Render: <span id=render_time></span> Seconds</font>

{include file="admin/report/online_users_footer.tpl"}
