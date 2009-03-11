<%
   if { [string match *.adp [ns_conn url]] } {
     ns_returnredirect index.nstk
     ns_adp_abort
   }
%>

<master src=master>

Url: <%=[ns_conn url]%><BR>
Location: <%=[ns_conn location]%><BR>
ServerPath: <%=[ns_info pageroot]%><BR>
PagePath: <%=[ns_info pageroot]%><BR>
Incr Test: @incr_test@

<P>

<B>Multirow:</B><BR>
<TABLE BORDER=1 CELLSPACING=0>
<multirow name=rows>
<TR><TD>@rows.name@</TD><TD>@rows.address@</TD></TR>
</multirow>
</TABLE>

<P>

<B>List:</B><BR>
<OL>
<list name=list>
<LI>@list:item@
</list>
</OL>

<P>

<if @time@ odd>
Odd Time: <%=[ns_fmttime $time]%>
<else>
Even Time: <%=[ns_fmttime $time]%>
</if>

<P>

Random number:<BR>
<if @random@ gt 50>
Number is greater than 50
<else>
Number less than 50
</if>

<P>

This is output from evaluated buffer:<P>

@email@

<P>

<include src=include>

<P>

<if @db@ ne "">
Database names: @names@
<P>

<B>Database Multirow:</B><BR>
<TABLE BORDER=1 CELLSPACING=0>
<multirow name=records>
<TR><TD>@records.id@</TD><TD>@records.value@</TD></TR>
</multirow>
</TABLE>

</if>
