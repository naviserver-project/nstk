# Tcl test page for index.nstk

set incr_test [nstk::cache incr incr_test]

# Create multirow
nstk::multirow create rows name address
nstk::multirow append rows "John Smith" "1 Main St"
nstk::multirow append rows "Bill Gates" "111 Liberty Sq"

# Create list
set list { One Two Three Four }

# Current time
set time [ns_time]
set hour [ns_fmttime [ns_time] "%H"]

# Random number
set random [ns_rand 100]

# custom template
set email {
Subject: Test email
Date: <%=[ns_fmttime [ns_time]]%>

Good <if @hour@ gt 15>Evening<else>Morning</if> John,

This is my test email.
}

# Eval template from the variable, same tags apply
set email [nstk::tmpl::evaldata $email]

# Database test, needs connection to database, by default it
# tries to pick first database pools
set dbpools [ns_configsection ns/db/pools]
if { $dbpools != "" } {

  set db [nstk::db::handle [ns_set key $dbpools 0]]

  if { $db != "" } {

    if { [nstk::cache get nstk:db] == "" } {
      nstk::db::exec "DROP TABLE nstk_test"
      nstk::db::exec "CREATE TABLE nstk_test (id INTEGER,value VARCHAR(32))"
      nstk::db::exec "INSERT INTO nstk_test(id,value) VALUES(1,'John')"
      nstk::db::exec "INSERT INTO nstk_test(id,value) VALUES(1,'Jim')"
      nstk::db::exec "INSERT INTO nstk_test(id,value) VALUES(1,'Mary')"
      nstk::db::exec "INSERT INTO nstk_test(id,value) VALUES(1,'Jessica')"
      nstk::db::exec "INSERT INTO nstk_test(id,value) VALUES(1,'Ivan')"
      nstk::cache set nstk:db $db
    }

    # List of first columns
    set names [nstk::db::list "SELECT value FROM nstk_test"]

    # Multirow datasource
    nstk::db::multirow records "SELECT id,value FROM nstk_test" -cache nstkdb -eval {
      set row(value) [string toupper $row(value)]
    }
    ns_log notice ${records:rowcount}
  }
}
