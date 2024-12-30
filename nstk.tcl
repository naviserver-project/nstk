# Author: Vlad Seryakov vlad@crystalballinc.com
# August 2005
#

#
# nstk - NaviServer ToolKit
#
# Toolkit namespace and procs
#

namespace eval nstk {

    variable version "nstk version 1.1"

    # Custom tags
    namespace eval tag {}

    # Cache API
    namespace eval cache {}

    # Database API
    namespace eval db {}

    # Template processing
    namespace eval tmpl {
      # currently processing page
      variable tstack ""
      # level in which a template is rendered
      variable tlevel 1
      # incremental template buffer counter
      variable blevel 0
      # to store special error code
      variable tstop NSTK_TMPL_STOP
    }

    # Returns configuration parameter, all params are taken from
    # the special section module/nstk of the current server
    proc config { name { default "" } { type "-exact" } } {
        set section "ns/server/[ns_info server]/module/nstk"
        return [eval ns_config $type $section $name $default]
    }
}

# Initialize nstk
ns_runonce {

    ns_cache_create __nstk_cache 0
    ns_cache_create __nstk_dbcache 0

    # Register templating filter for given extension
    set ext [nstk::config extension nstk]
    ns_register_filter postauth GET *.$ext ::nstk::tmpl::filter
    ns_register_filter postauth POST *.$ext ::nstk::tmpl::filter

    ns_log Notice nstk::init templating filter installed for *.$ext
}

# Returns 1 if given string represents true
proc nstk::true { value } {

    return [regexp -nocase {^(1|t|true|y|yes|on|enabled)$} $value]
}

# Perform get/set operations on a multirow datasource.
# Datasource is list of arrays for each row.
# For datasource ds, rows are named as ds:1, ds:2, ds:3 ...
#
# There are two special variables that describe multirow datasource:
#  ds:rowcount - holds total number of rows in the datasource
#  ds:columns - holds list of column names for each row
#
proc nstk::multirow { op name args } {

    set level [expr [info level] - 1]
    upvar #$level $name:rowcount rowcount $name:columns columns

    switch -exact -- $op {
      create {
        set rowcount 0
        set columns $args
      }

      drop {
        if { [info exists columns] } { unset columns }
        if { [info exists rowcount] } {
          while { $rowcount } {
            upvar #$level $name:$rowcount row
            if { [info exists row] } { unset row }
            incr rowcount -1
          }
        }
      }

      append {
        incr rowcount
        upvar #$level $name:$rowcount row
        for { set i 0 } { $i < [llength $columns] } { incr i } {
          set key [lindex $columns $i]
          set value [lindex $args $i]
          set row($key) $value
        }
        set row(rownum) $rowcount
      }

      update {
        upvar #$level $name:[lindex $args 0] row
        for { set i 0 } { $i < [llength $columns] } { incr i } {
          set key [lindex $columns $i]
          set value [lindex $args [expr $i+1]]
          set row($key) $value
        }
        set row(rownum) $rowcount
      }

      local {
        upvar #$level $name:[lindex $args 0] row
        foreach key [array names row] {
          upvar 1 $key var
          set var $row($key)
        }
      }

      size {
        return $rowcount
      }

      get {
        upvar #$level $name:[lindex $args 0] row
        return $row([lindex $args 1])
      }

      set {
        upvar #$level $name:[lindex $args 0] row
        foreach { column value } [lrange $args 1 end] {
          set row($column) $value
        }
      }
    }
}

# Returns value or default if value is empty
proc nstk::nvl { value { default "" } } {

    if { ![string equal $value {}] } { return $value }
    return $default
}

# Checks variable name for existence and empty value
# and returns default if this is true. Accepts variable name to be checked,
# not value itself.
proc nstk::coalesce { name { default "" } } {

    upvar 1 $name var
    if { [array exists var] ||
         ([info exists var] && ![string equal $var {}]) } {
      return $var
    }
    return $default
}

# Reads a text file.
#  path The absolute path to the file
#  Returns a string with the contents of the file.
proc nstk::read_file { path } {

    if { ![file exists $path] } {
       return
    }
    if { [catch {
      set fd [::open $path]
      fconfigure $fd -translation binary
      set text [::read $fd]
      ::close $fd
    } errmsg] } {
      ns_log Error nstk::read_file: $errmsg
      catch { ::close $fd }
      return
    }
    return $text
}

# Creates a text file.
#  path The absolute path to the file
#  data to be saved
#  Returns a string with the contents of the file.
proc nstk::write_file { path data { mode w } } {

    if { [catch {
      set fd [::open $path $mode]
      fconfigure $fd -translation binary
      puts -nonewline $fd $data
      ::close $fd
    } errmsg] } {
      ns_log Error nstk::write_file: $errmsg
      catch { ::close $fd }
      return -1
    }
    return 0
}

# Send email with optional attachements
# Returns -1 on error or 0 on success
#  -headers is a list with additional SMTP headers in the form: name value ...
#  -domain specifies which domain name to use in case of incomplete email from address
#  -files specifies list with absolute patch of files to be attached
#  -bcc, -cc specifies additonal address to be sent by BCC/CC
proc nstk::sendmail { to from subject body args } {

    ns_parseargs { {-headers ""}
                   {-domain ""}
                   {-files ""}
                   {-cc ""}
                   {-bcc ""}
                   {-error ""}
                   {-content_type "text/plain"} } $args

    if { $error != "" } {
      upvar $error errmsg
    }
    # Check from email and append current host name if missing
    if { [string first @ $from] == -1 } {
      append from @ [nstk::nvl $domain [ns_info hostname]]
    }
    if { [string first @ $to] == -1 } {
      append to @ [nstk::nvl $domain [ns_info hostname]]
    }
    # Append attachements
    if { $files != "" } {
      set boundary "[pid][clock seconds][clock clicks][ns_rand]"
      lappend headers "MIME-Version" "1.0" \
                      "Content-Type" "multipart/mixed; boundary=\"$boundary\""
      # Insert text as a first part of the envelope
      set body "--$boundary\nContent-Type: $content_type; charset=us-ascii\n\n$body\n\n"
      foreach name $files {
        append body "--$boundary\n"
        switch [set type [ns_guesstype $name]] {
         "" - "text/plain" { set type "application/octet-stream" }
        }
        append body "Content-Type: $type; name=\"[file tail $name]\"\n"
        append body "Content-Disposition: attachment; filename=\"[file tail $name]\"\n"
        append body "Content-Transfer-Encoding: base64\n\n"
        append body [ns_uuencode [nstk::read_file $name]] "\n\n"
      }
    } else {
      # simple MIME envelope
      if { $content_type != "text/plain" } {
        lappend headers MIME-Version 1.0 Content-Type $content_type
      }
    }
    # Send the message without submitting into message queue
    set hdrs [ns_set new]
    foreach { name value } $headers {
      switch [set name [string tolower $name]] {
       cc - bcc { append $name $value, }
      }
      ns_set iupdate $hdrs $name $value
    }
    if { [catch { ns_sendmail $to $from $subject $body $hdrs $bcc $cc } errmsg] } {
      nstk::conn::log Error nstk::sendmail $from: $to: $subject: $errmsg
    }
    return 0
}

# Generic caching mechanism, global throughout the whole server.
# Examples:
#   nstk::cache set john "111"
#   set id [nstk::cache get john]
#   nstk::cache flush john
proc nstk::cache { command key args } {

    set val [lindex $args 0]
    set ttl [lindex $args 1]

    switch -exact $command {

      exists {
        return [nstk::cache::exists __nstk_cache $key]
      }

      get {
        return [nstk::cache::get __nstk_cache $key -default $val]
      }

      incr {
        return [nstk::cache::incr __nstk_cache $key -incr $val -expires $ttl]
      }

      set {
        nstk::cache::put __nstk_cache $key $val -expires $ttl
      }

      append {
        nstk::cache::append __nstk_cache $key $val -expires $ttl
      }

      lappend {
        nstk::cache::lappend __nstk_cache $key $val -expires $ttl
      }

      unset -
      flush  {
        nstk::cache::flush __nstk_cache $key
      }

      names {
        # List of names by pattern
        set result ""
        foreach name [nstk::cache::keys __nstk_cache $key] { lappend result $name }
        return $result
      }

      values {
        # List of key/values by pattern
        set result ""
        foreach name [nstk::cache::keys __nstk_cache $key] {
          ::lappend result $name [nstk::cache::get __nstk_cache $name]
        }
        return $result
      }

      cleanup {
      }

      default {
        error "nstk::cache: Invalid command: $command"
      }
    }
}

# Create new cache
proc nstk::cache::create { cache args } {

    ns_parseargs { {-params ""} {-expires ""} {-size 0} {-timeout ""} {-maxentry ""} } $args

    if { $expires > 0 } { ::lappend params -expires $expires }
    if { $timeout > 0 } { ::lappend params -timeout $timeout }
    if { $maxentry > 0 } { ::lappend params -maxentry $maxentry }

    eval ns_cache_create $params $cache $size
}

# Returns 1 if cache entry exists
proc nstk::cache::exists { cache key args } {

    if { [catch { ns_cache_eval $cache $key { error "no entry" } }] } { return 0 }
    return 1
}

# Update cache entry
proc nstk::cache::put { cache key val args } {

    ns_parseargs { {-params ""} {-expires ""} {-timeout ""} } $args

    if { $expires > 0 } { ::lappend params -expires $expires }
    if { $timeout > 0 } { ::lappend params -timeout $timeout }

    eval "ns_cache_eval $params -force -- $cache {$key} {return {$val}}"
}

# Evaluate the script and updzte cache entry with result
proc nstk::cache::run { cache key script args } {

    ns_parseargs { {-params ""} {-expires ""} {-timeout ""} {-force ""} } $args

    if { [nstk::true $force] } { ::lappend params -force }
    if { $expires > 0 } { ::lappend params -expires $expires }
    if { $timeout > 0 } { ::lappend params -timeout $timeout }

    uplevel "ns_cache_eval $params -- $cache {$key} {$script}"
}

# Returns cache entry value
proc nstk::cache::get { cache key args } {

    ns_parseargs { {-params ""} {-default ""} {-timeout ""} args } $args

    if { $timeout > 0 } { ::lappend params -timeout $timeout }

    return [nstk::nvl [eval "ns_cache_eval $params -- $cache {$key} {}"] $default]
}

# Increment cache entry value
proc nstk::cache::incr { cache key args } {

    ns_parseargs { {-params ""} {-incr 1} {-expires ""} {-timeout ""} } $args

    if { $expires > 0 } { ::lappend params -expires $expires }
    if { $timeout > 0 } { ::lappend params -timeout $timeout }

    return [eval "ns_cache_incr $params -- $cache {$key} $incr"]
}

# Append data to cache entry
proc nstk::cache::append { cache key val args } {

    ns_parseargs { {-params ""} {-expires ""} {-timeout ""} args } $args

    if { $expires > 0 } { ::lappend params -expires $expires }
    if { $timeout > 0 } { ::lappend params -timeout $timeout }

    return [eval "ns_cache_append $params -- $cache {$key} {$val} $args"]
}

# Append list elements to cache entry
proc nstk::cache::lappend { cache key val args } {

    ns_parseargs { {-params ""} {-expires ""} {-timeout ""} args } $args

    if { $expires > 0 } { ::lappend params -expires $expires }
    if { $timeout > 0 } { ::lappend params -timeout $timeout }

    return [eval "ns_cache_lappend $params -- $cache {$key} {$val} $args"]
}

# Flush cache entry from the cache
proc nstk::cache::flush { cache args } {

    eval ns_cache_flush -glob $cache $args
}

# Returns cache entry names by pattern
proc nstk::cache::keys { cache { key "" } } {

    return [eval ns_cache_keys $cache $key]
}

# Returns all created caches
proc nstk::cache::names {} {

    return [ns_cache_names]
}

# Returns a database connection handle. Returns the same database handle
# for all subsequent calls until nstk::db::release is called.  This allows
# the same handle to be used easily across multiple procedures.
# Returns A database handle
proc nstk::db::handle { { pool "" } { count 1 } } {

    global __nstk_dbhandle

    if { [info exists __nstk_dbhandle] } {
      return $__nstk_dbhandle
    }
    if { $pool == "" } {
      set pool [::nstk::config database nstk]
    }
    if { [catch { set __nstk_dbhandle [ns_db gethandle $pool $count] } errmsg] } {
      ns_log Error nstk::db::handle: $errmsg
      return
    }
    return $__nstk_dbhandle
}

# Releases a database handle previously requested with nstk::db::handle.
proc nstk::db::release { args } {

    global __nstk_dbhandle

    if { [info exists __nstk_dbhandle] } {
      if { [ns_db connected $__nstk_dbhandle] } {
        ns_db releasehandle $__nstk_dbhandle
      }
      unset __nstk_dbhandle
    }
}

# Begins a database transaction, nested calls are allowed, actuall begin will happen
# on the first call only, all subsequent calls will result in increasing transaction counter.
# Returns 0 on success, -1 on error
proc nstk::db::begin { args } {

    global __nstk_dbtransaction

    ns_parseargs { -db } $args

    if { ![info exists db] } {
      set db [nstk::db::handle]
    }
    if { ![info exists __nstk_dbtransaction] || $__nstk_dbtransaction < 0 } {
      set __nstk_dbtransaction 0
    }
    incr __nstk_dbtransaction
    if { $__nstk_dbtransaction == 1 } {
      if { [catch { ns_db dml $db "BEGIN TRANSACTION" } errmsg] } {
        ns_log Error nstk::db::begin: $errmsg
        set __nstk_dbtransaction 0
        return -1
      }
    }
    return 0
}

# Commits a database transaction. Nested calls are allowd, actual commit will
# happend when the transaction counter will reach zero.
# Returns 0 on success, -1 on error
proc nstk::db::commit { args } {

    global __nstk_dbtransaction

    ns_parseargs { -db } $args

    if { ![info exists db] } {
      set db [nstk::db::handle]
    }
    if { ![info exists __nstk_dbtransaction] || $__nstk_dbtransaction < 0 } {
      set __nstk_dbtransaction 0
    }
    incr __nstk_dbtransaction -1
    if { $__nstk_dbtransaction == 0 } {
      if { [catch { ns_db dml $db "COMMIT TRANSACTION" } errmsg] } {
        ns_log Error nstk::db::commit: $errmsg
        set __nstk_dbtransaction 0
        return -1
      }
    }
    return 0
}

# Rollbacks a database transaction.
proc nstk::db::rollback { args } {

    global __nstk_dbtransaction

    ns_parseargs { -db } $args

    if { ![info exists db] } {
      set db [nstk::db::handle]
    }
    if { ![info exists __nstk_dbtransaction] || $__nstk_dbtransaction < 0 } {
      set __nstk_dbtransaction 0
    }
    if { $__nstk_dbtransaction > 0 } {
      if { [catch { ns_db dml $db "ROLLBACK TRANSACTION" } errmsg] } {
        ns_log Error nstk::db::rollback: $errmsg
        set __nstk_dbtransaction 0
        return -1
      }
    }
    set __nstk_dbtransaction 0
    return 0
}

# Returns number of rows affected by last INSERT,UPDATE or DELETE statement.
proc nstk::db::rowcount { args } {

    ns_parseargs { -db } $args

    if { ![info exists db] } {
      set db [nstk::db::handle]
    }

    switch -glob [ns_db dbtype $db] {
     PostgreSQL {
       set count [ns_pg ntuples $db]
     }
     Sybase {
       set count [::nstk::db::value $db "SELECT @@rowcount"]
     }
     default {
       error "Unsupported database driver: [ns_db dbtype $db]: [ns_db driver $db]"
     }
    }
    return $count
}

# Returns the first column of the result.
# If the query doesn't return a row, returns -default value
#  -default if values is null return default
#  -db existing database handle
#  -cache specifies cache name to use
#  -force t tells to ignore existing cache
#  -expires set the time to live for the cache
proc nstk::db::value { sql args } {

    ns_parseargs { {-db ""}
                   {-colname ""}
                   {-colindex 0}
                   {-default ""}
                   {-cache ""}
                   {-force f}
                   {-expires ""} } $args

    if { $cache != "" } {
      return [nstk::cache::run __nstk_dbcache $cache {
                   return [nstk::db::value $sql \
                              -db $db \
                              -default $default \
                              -colname $colname \
                              -colindex $colindex]
                   } -expires $expires -force $force]
    }

    if { $db == "" } {
      set db [nstk::db::handle]
    }

    if [catch { set query [ns_db 0or1row $db $sql] } errmsg] {
      ns_log Error nstk::db::value: $id: $errmsg: $sql
      return
    }

    set result $default
    if { $query != "" } {
      if { $colname != "" } {
        set colindex [ns_set ifind $query $colname]
      }
      if { $colindex >= 0 && $colindex < [ns_set size $query] } {
        set result [ns_set value $query $colindex]
      }
    }
    return $result
}

# Returns the first column of each row and returns it as a Tcl list
#  -db existing database handle
#  -cache specifies cache name to use
#  -force t tells to ignore existing cache
#  -expires set the time to live for the cache
#  -maxrows specify max number of rows to return
#  -colindex, -colname specify column index or name
proc nstk::db::list { sql args } {

    ns_parseargs { {-db ""}
                   {-force f}
                   {-cache ""}
                   {-colindex 0}
                   {-colname ""}
                   {-expires ""}
                   {-maxrows ""} } $args

    if { $cache != "" } {
      return [nstk::cache::run __nstk_dbcache $cache {
                   return [nstk::db::list $sql \
                              -db $db \
                              -maxrows $maxrows \
                              -colname $colname \
                              -colindex $colindex]
                   } -expires $expires -force $force]
    }

    if { $db == "" } {
      set db [nstk::db::handle]
    }
    if [catch { set query [ns_db select $db $sql] } errmsg] {
      ns_log Error nstk::db::list: $id: $errmsg: $sql
      return
    }
    # No records found
    if { $query == "" } {
      return
    }
    set rowcount 0
    set result ""
    while { [ns_db getrow $db $query] } {
       incr rowcount
       # Return column by name, find column index and use it
       if { $colname != "" } {
         set size [ns_set size $query]
         for { set colindex 0 } { $colindex < $size } { incr colindex } {
           if { [ns_set key $query $colindex] == $colname } {
             set colname ""
             break
           }
         }
       }
       # Return column by index
       lappend result [ns_set value $query $colindex]
       # Stop if maxrows has been reached
       if { $rowcount == $maxrows } {
         ns_db flush $db
         break
       }
    }
    return $result
}

# Returns a list of Tcl lists with each sublist containing the columns
# returned by the database; if no rows are returned by the
# database, returns the empty string
#  -db existing database handle
#  -plain returns result as plain list, not list of lists
#  -array returns list of arrays for each record
#  -cache specifies cache name to use
#  -force t tells to ignore existing cache
#  -expires set the time to live for the cache
#  -maxrows specify max number of rows to return
#  -colindex, -colname specify column index or name
#  -colcount spcifies how many columns to return from each record
proc nstk::db::multilist { sql args } {

    ns_parseargs { {-db ""}
                   {-force f}
                   {-cache ""}
                   {-expires ""}
                   {-array f}
                   {-plain f}
                   {-maxrows ""}
                   {-colcount ""}
                   {-colindex ""}
                   {-colname ""} } $args

    if { $cache != "" } {
      return [nstk::cache::run __nstk_dbcache $cache {
                   return [nstk::db::multilist $sql \
                              -db $db \
                              -plain $plain \
                              -array $array \
                              -maxrows $maxrows \
                              -colcount $colcount \
                              -colname $colname \
                              -colindex $colindex]
                   } -expires $expires -force $force]
    }

    if { $db == "" } {
      set db [nstk::db::handle]
    }

    if [catch { set query [ns_db select $db $sql] } errmsg] {
      ns_log Error nstk::db::multilist: $id: $errmsg: $sql
      return
    }
    # No records found
    if { $query == "" } {
      return ""
    }
    set rowcount 0
    set result ""
    while { [ns_db getrow $db $query] } {
        incr rowcount
        set row ""
        set size [ns_set size $query]
        # Return only specified column by index
        if { $colindex != "" } {
          if { $array == "t" } {
            lappend row [ns_set key $query $i]
          }
          set value [ns_set value $query $colindex]
          lappend row $value
          set size 0
        }
        for { set i 0 } { $i < $size } { incr i } {
          # Return only specified column by name
          if { $colname != "" && [ns_set key $query $i] == $colname } {
            if { $array == "t" } {
              lappend row [ns_set key $query $i]
            }
            set value [ns_set value $query $i]
            lappend row $value
            break
          }
          # All columns
          if { $array == "t" } {
            lappend row [ns_set key $query $i]
          }
          set value [ns_set value $query $i]
          lappend row $value
          # Stop if reached column limit
          if { [string is integer -strict $colcount] && $i >= $colcount } {
            break
          }
        }
        if { $plain == "f" } {
          lappend result $row
        } else {
          ::foreach item $row {
            lappend result $item
          }
        }
        # Stop if maxrows has been reached
        if { $rowcount == $maxrows } {
          ns_db flush $db
          break
        }
    }
    return $result
}

# Performs the SQL query $sql that returns 0 or 1 row,
# setting variables to column values.
#  -prefix specifies additional name prefix to make column names different
#  -db existing database handle
#  -array sets array with values not Tcl variables
#  -cache specifies cache name to use
#  -force t tells to ignore existing cache
#  -expires set the time to live for the cache
#  -level at which level to create variables
# Returns -1 in case of error
proc nstk::db::multivalue { sql args } {

    ns_parseargs { {-level ""}
                   {-db ""}
                   {-prefix ""}
                   {-force f}
                   {-array ""}
                   {-cache ""}
                   {-expires ""} } $args

    if { $cache != "" } {
      set result [nstk::cache::run __nstk_dbcache $cache {
                   return [nstk::db::multilist $sql \
                              -level $level \
                              -db $db \
                              -plain t \
                              -array t]
                   } -expires $expires -force $force]
      if { $result == "" } {
        return -1
      }
      ::foreach { name value } $result {
        if { $array != "" } {
          upvar #$level ${array}($name) _var
          set _var $value
        } else {
          upvar #$level ${prefix}$name _var
          set _var $value
        }
      }
      return 0
    }

    if { $db == "" } {
      set db [nstk::db::handle]
    }
    if { $level == "" } {
      set level [expr [info level] - 1]
    }

    if [catch { set query [ns_db 0or1row $db $sql] } errmsg] {
      ns_log Error nstk::db::multivalue: $id: $errmsg: $sql
      return -1
    }
    # No records found
    if { $query == "" } {
      return -1
    }
    set i 0
    set size [ns_set size $query]
    while { $i < $size } {
      set name [ns_set key $query $i]
      set value [ns_set value $query $i]
      if { $array != "" } {
        upvar #$level ${array}($name) _var
        set _var $value
      } else {
        upvar #$level ${prefix}$name _var
        set _var $value
      }
      incr i
    }
    return 0
}

# Execute database query and create multirow datasource name,  each result row will create
# separate multirow row. If eval si not empty, it will be executed for every row. Local
# array row will hold all column values for the current row in the eval script.
#  -db existing database handle
#  -level at which level to create datasource
proc nstk::db::multirow { name sql args } {

    ns_parseargs { {-level ""}
                   {-db ""}
                   {-force f}
                   {-eval ""}
                   {-cache ""}
                   {-colindex 0}
                   {-colname ""}
                   {-expires ""}
                   {-maxrows ""} } $args

    if { $level == "" } {
      set level [expr [info level] - 1]
    }

    upvar #$level $name:rowcount rowcount ${name}:columns columns
    set rowcount 0

    if { $cache != "" } {
      set result [nstk::cache::run __nstk_dbcache $cache {
                   return [nstk::db::multilist $sql \
                              -db $db \
                              -maxrows $maxrows \
                              -array t]
                   } -expires $expires -force $force]
      # Execute custom code for each row
      ::foreach rec $result {
        incr rowcount
        # Build column array
        if { $rowcount == 1 } {
          set columns {}
          ::foreach { var value } $rec {
            lappend columns $var
          }
        }
        upvar #$level ${name}:$rowcount row
        set row(rownum) $rowcount
        ::foreach { var value } $rec {
          set row($var) $value
        }
        if { $eval != "" } {
          set rc [catch { uplevel #$level "upvar 0 ${name}:$rowcount row; $eval" } errmsg]
          # Examine status for special situations
          switch $rc {
           0 {}
           4 {
               incr rowcount -1
               continue
             }
           2 -
           3 {
               incr rowcount -1
               ns_db flush $db
               break
           }
           default {
               global errorInfo
               ns_log Error nstk::db::multirow "$name: $sql: $errmsg: $errorInfo"
           }
          }
        }
      }
      return $rowcount
    }

    if { $db == "" } {
      set db [nstk::db::handle]
    }

    if { [catch { set query [ns_db select $db $sql] } errmsg] } {
      ns_log Error nstk::db::multirow: $errmsg: $sql
      return -1
    }

    while { [ns_db getrow $db $query] } {
      set size [ns_set size $query]
      incr rowcount
      # Build column array
      if { $rowcount == 1 } {
        set columns {}
        for { set i 0 } { $i < $size } { incr i } {
          lappend columns [ns_set key $query $i]
        }
      }
      upvar #$level ${name}:$rowcount row
      set row(rownum) $rowcount
      for { set i 0 } { $i < $size } { incr i } {
        set var [ns_set key $query $i]
        set value [ns_set value $query $i]
        set row($var) $value
      }
      # Execute custom code for each row
      if { $eval != "" } {
        set rc [catch { uplevel #$level "upvar 0 ${name}:$rowcount row; $eval" } errmsg]
        # Examine status for special situations
        switch $rc {
         0 {}
         4 {
             incr rowcount -1
             continue
           }
         2 -
         3 {
             incr rowcount -1
             ns_db flush $db
             break
         }
         default {
             global errorInfo
             ns_log Error nstk::db::multirow "$name: $sql: $errmsg: $errorInfo"
         }
        }
      }
    }
    return $rowcount
}

# Usage: nstk::db::foreach sql code args
# Performs the SQL query $sql, executing code once for each row with
# variables set to column values.
# Returns -1 on error or number of rows processed
proc nstk::db::foreach { sql code args } {

    ns_parseargs { {-prefix ""} -db -level } {} $args

    if { ![info exists level] } {
      set level [expr [info level] - 1]
    }
    if { ![info exists db] } {
      set db [nstk::db::handle]
    }
    set rownum 0
    if [catch { set query [ns_db select $db $sql] } errmsg] {
      ns_log Error nstk::db::foreach: $errmsg: $sql
      return -1
    }
    while { [ns_db getrow $db $query] } {
      incr rownum
      for { set i 0 } { $i < [ns_set size $query] } { incr i } {
        set name [ns_set key $query $i]
        upvar #$level $prefix$name var
        set var [ns_set value $query $i]
      }
      set rc [catch { uplevel #$level $code } errmsg]
      switch $rc {
        0 -
        4 {}
        2 -
        3 {
           ns_db flush $db
           break
        }
        default {
           global errorInfo errorCode
           error $errmsg $errorInfo $errorCode
        }
      }
    }
    return $rownum
}

# Executes SQL statement, returns 0 if successful
proc nstk::db::exec { sql args } {

    ns_parseargs { {-prefix ""} -db } $args

    if { ![info exists db] } {
      set db [nstk::db::handle]
    }
    # Execute SQL statement
    if [catch { ns_db exec $db $sql } errmsg] {
      ns_log Error nstk::db::exec: $errmsg: $sql
      return -1
    }
    return 0
}

#
# nstk - NaviServer ToolKit
#
#  Templating engine
#

# Template filter, process template and return the output
proc nstk::tmpl::filter { args } {

    # Path to the template page
    set _url "[ns_info pageroot]/[::file rootname [ns_conn url]]"

    if { [catch {

      nstk::tmpl::init
      set output [nstk::tmpl::evalfile $_url]

    } errmsg] } {

      # Signal to stop template processing, this error means the script
      # produced the output and returned it to the client
      if { $errmsg == [nstk::tmpl::stop 0] } {
        return filter_return
      }
      # We do quotehtml here to avoid malicios code in the request to be
      # executed in the clients browser
      global errorInfo
      ns_log Error nstk::tmpl::filter: [ns_quotehtml $_url]: $errorInfo

      # Check if we have custom error page to be used in case of fatal error
      set error_page [nstk::config error_page ""]
      if { $error_page != "" } {
        ns_returnredirect $error_page
        return filter_return
      }
      set output "<html><body><p>Internal Server Error in [ns_quotehtml $_url]:
                  <pre>[ns_quotehtml $errorInfo]</pre></body></html>"
    }
    if { [string length $output] > 0 } {
      # Expire dynamic pages
      ns_setexpires -3600
      ns_return 200 text/html $output
    }
    return filter_return
}

# Performs template initialization
proc nstk::tmpl::init {} {

    variable tstack
    variable tlevel

    set tstack ""
    set tlevel 1
}

# Set the path of the template to be executed.
#  path absolute path to the next template to parse.
proc nstk::tmpl::setfile { path } {

    variable tstack

    lappend tstack $path
}

# Returns currently executed template file
proc nstk::tmpl::file {} {

    variable tstack

    return [lindex $tstack end]
}

# Returns the execution stack length
proc nstk::tmpl::length {} {

    variable tstack

    return [llength $tstack]
}

# Returns directory of currently executed template file
proc nstk::tmpl::dirname {} {

    variable tstack

    return [::file dirname [lindex $tstack end]]
}

# Returns full path to the included template or master
proc nstk::tmpl::include { file } {

    set rpath [ns_normalizepath [nstk::tmpl::dirname]/$file]
    if { [::file exists $rpath.adp] } {
      return $rpath
    }
    set root [nstk::config path:include [ns_info pageroot]/index]
    return [ns_normalizepath $root/$file]
}

# Global execution level at which template is being evaluated.
# Returns current Tcl execution level
proc nstk::tmpl::level { } {

    variable tlevel

    return $tlevel
}

# Change global template level
proc nstk::tmpl::setlevel { newlevel } {

    variable tlevel

    set tlevel $newlevel
}

# Operations with template dynamic buffers
proc nstk::tmpl::buffer { what { name "" } { value "" } } {

    variable blevel

    set level [nstk::tmpl::level]

    switch $what {
     init {
        incr blevel
        upvar #$level __tmpl_buffer_$blevel buffer
        foreach key { code output master } { set buffer($key) "" }
        # It may exist if there was <slave> tag in the document
        if { ![::info exists buffer(slave)] } {
          set buffer(slave) ""
        }
     }
     set {
        switch $name {
         slave {
           upvar #$level "__tmpl_buffer_[expr $blevel + 1]" buffer
           set buffer(slave) $value
         }
         default {
           upvar #$level __tmpl_buffer_$blevel buffer
           set buffer($name) $value
         }
        }
     }
     get {
        upvar #$level __tmpl_buffer_$blevel buffer
        return $buffer($name)
     }
     clear {
        upvar #$level __tmpl_buffer_$blevel buffer
        unset buffer
        incr blevel -1
     }
     reset {
        upvar #$level __tmpl_buffer_$blevel buffer
        foreach key { code slave output master } { set buffer($key) "" }
     }
     append {
       upvar #$level __tmpl_buffer_$blevel buffer
       append buffer($name) $value
     }
    }
}

# Caches template data and code files
#  type - tcl or adp
proc nstk::tmpl::cache { type path } {

    set level [nstk::tmpl::level]
    set mtime0 [info procs nstk_${type}_$path]
    set mtime1 [::file mtime $path.$type]
    # Verify file modification time
    if { $mtime0 == "" || [$mtime0 1] != $mtime1 } {
      if { [catch {
        set fd [open $path.$type]
        set code [read $fd]
        close $fd
      } errmsg] } {
        ns_log Error nstk::tmpl::cache: $type: $path: $errmsg
        set code ""
      }
      if { $type == "adp" } {
        set code [nstk::tmpl::compile $code]
      }
      ::proc nstk_${type}_$path {{mtime 0}} "
         if { \$mtime } { return $mtime1 }
         uplevel #$level { $code }
      "
    }
    # Run the proc
    nstk_${type}_$path
}

# Executes template script if exists and evaluates template embedded tags
#  path   absolute path to the template without extension
#  params  list of pairs of variables and values to be created
# Returns parsed and evaluated page
proc nstk::tmpl::evalfile { path { params "" } } {

    set level [nstk::tmpl::level]
    # Initialize the ADP buffer
    nstk::tmpl::buffer init
    # Declare any variables passed in to an include or master
    foreach { key value } $params {
      uplevel #$level "set $key \"$value\""
    }
    # Append currently processed template file to the execution stack
    nstk::tmpl::setfile $path
    # Execute Tcl code first
    if { [catch {
      while 1 {
        if { ![::file exists $path.tcl] } { break }
        # Remember current position in the execution stack
        set len [nstk::tmpl::length]
        if { $len > 5 } {
          ns_log Notice nstk::tmpl::evalfile: $path
          error "Infinite template loop"
        }
        # Run the code
        nstk::tmpl::cache tcl $path
        # If template has been switched inside the script, run the new one
        if { [nstk::tmpl::length] == $len } { break }
        set path [nstk::tmpl::file]
      }
    } errMsg] } {
      # Return without error in case of special abort
      if { $errMsg == [nstk::tmpl::stop 0] } { return }
      global errorInfo
      error $errMsg $errorInfo
    }
    # If we have ADP file, generate output
    if { [::file exists "$path.adp"] } {
      # Run the code
      nstk::tmpl::cache adp $path
      set output [nstk::tmpl::buffer get output]
      # Call the master template if one has been defined
      set master [nstk::tmpl::buffer get master]
      if { $master != "" } {
        # Save current output for <slave> tag
        nstk::tmpl::buffer set slave $output
        # Call master template with passed properties
        set output [nstk::tmpl::evalfile $master]
      }
      nstk::tmpl::buffer clear
      return $output
    } else {
      ns_log Error nstk::tmpl::evalfile: $path.adp not found
    }
    nstk::tmpl::buffer clear
    # If file is not set it means we couldn't resolve any template or script
    if { [nstk::tmpl::file] == "" } {
      ns_log Error nstk::tmpl::evalfile template or script is not found: $path
      return "The requested URL was not found on this server: '[ns_quotehtml [ns_conn url]]'"
    }
}

# Evaluates buffer with template tags
#  data  string buffer with the template
#  params  list of pairs of variables and values to be created
# Returns parsed and evaluated page
proc nstk::tmpl::evaldata { data { params "" } } {

    # Save current buffer level
    set save_level [nstk::tmpl::level]
    # Set adp level to our parent
    set level [::expr [info level]-1]
    nstk::tmpl::setlevel $level
    # Initialize the buffer
    nstk::tmpl::buffer init
    # Declare any variables passed in to an include or master
    foreach { key value } $params {
      uplevel #$level "set $key \"$value\""
    }
    # Run the code
    set code [nstk::tmpl::compile $data]
    switch [::catch { uplevel #$level $code } errmsg] {
     0 - 2 - 3 - 4 {}
     default {
       nstk::tmpl::setlevel $save_level
       global errorInfo
       error $errmsg $errorInfo
     }
    }
    set output [nstk::tmpl::buffer get output]
    # Call the master template if one has been defined
    set master [nstk::tmpl::buffer get master]
    if { $master != "" } {
      # Save current output for <slave> tag
      nstk::tmpl::buffer set slave $output
      # Call master template with passed properties
      set output [nstk::tmpl::evalfile $master]
    }
    nstk::tmpl::buffer clear
    nstk::tmpl::setlevel $save_level
    return $output
}

# Stops template processing
proc nstk::tmpl::stop { { fire 1 } } {

    variable tstop

    if { $fire } { error $tstop }
    return $tstop
}

# Writes to the template output buffer
#  text A string containing text or markup.
proc nstk::tmpl::write { text } {

    nstk::tmpl::buffer append output $text
}

# Parses a template by calling ns_adp_parse and putting the result into
# template output buffer.
#  chunk   A template
proc nstk::tmpl::parse { chunk } {

    set chunk [ns_adp_parse -string $chunk]
    if { [string is space $chunk] } { return }
    regsub -all {[]["\\$]} $chunk {\\&} chunk ;# Escape quotes and other special symbols"
    nstk::tmpl::data $chunk
}

# Puts data string into template output buffer.
#  text  string to be output, double quotes should be escaped
proc nstk::tmpl::data { text } {

    nstk::tmpl::code "nstk::tmpl::write \"$text\""
}

# Converts a template into a chunk of Tcl code.
#  chunk      A string containing the template
#  subst      1 if @..@ variables should be converted into Tcl variables
# Returns The compiled code.
proc nstk::tmpl::compile { chunk { subst 1 } } {

    nstk::tmpl::buffer set code ""
    # Substitute standard <% ... %> tags with our own Tcl handler
    regsub -all {<%} $chunk {<tcl>} chunk
    regsub -all {%>} $chunk {</tcl>} chunk
    nstk::tmpl::parse $chunk
    set code [nstk::tmpl::buffer get code]
    if { $subst } {
      while {[regsub -all {@([a-zA-Z0-9_:]+)\.([a-zA-Z0-9_:]+)@} $code {${\1(\2)}} code]} {}
      while {[regsub -all {@([a-zA-Z0-9_:]+)@} $code {${\1}} code]} {}
    }
    regsub -all {@~} $code {@} code
    return $code
}

# Puts a line of code to the template output buffer. Newlines is added
# after code automatically.
#  code  Tcl code
proc nstk::tmpl::code { str } {

    nstk::tmpl::buffer append code " $str \n"
}

#
# NaviServer ToolKit
#
# Custom tags
#

# Generic wrapper for registered tag handlers.
proc nstk::tag::create { name args body } {

    if { [llength $args] == 2 } {
      set chunk chunk
      set endtag /$name
    } else {
      set chunk ""
      set endtag ""
    }
    eval "
    proc tag_$name { $chunk params } {
        set data \[ns_adp_dump\]
        regsub -all {\[\]\[\"\\\$\]} \$data {\\\\&} data
        nstk::tmpl::data \$data
        ns_adp_trunc
        $body
        return {}
    }
    ns_register_adptag $name $endtag nstk::tag::tag_$name"
}

nstk::tag::create tcl { chunk params } {

    if { [string index $chunk 0] == "=" } {
      nstk::tmpl::code "nstk::tmpl::write [string range $chunk 1 end]"
    } else {
      nstk::tmpl::code $chunk
    }
}

# Set the master template.
nstk::tag::create master { params } {

    switch [ns_set iget $params mode] {
     default {
       set src [ns_set iget $params src]
       if { $src == "" } { set src index }
     }
    }
    nstk::tmpl::code "nstk::tmpl::buffer set master \[nstk::tmpl::include $src\]"
}

# Insert the slave template
nstk::tag::create slave { params } {

    nstk::tmpl::code "nstk::tmpl::write \[nstk::tmpl::buffer get slave\]"
}

# Include another template in the current template
nstk::tag::create include { params } {

    set args ""
    for { set i 0 } { $i < [ns_set size $params] } { incr i } {
      set key [ns_set key $params $i]
      if { $key != "src" } { append args " $key {[ns_set value $params $i]}" }
    }
    nstk::tmpl::code "nstk::tmpl::write \[nstk::tmpl::evalfile \[nstk::tmpl::include [ns_set iget $params src]\] {$args}\]"
}

# Repeat chunk for each row
nstk::tag::create multirow { chunk params } {

    set name [ns_set iget $params name]

    nstk::tmpl::code "
     for { set _row$name 1 } { \$_row$name <= \${$name:rowcount} } { incr _row$name } {
       upvar 0 $name:\$_row$name $name
       set $name:rownum \$_row$name
       if { !\[info exists $name\] } { continue }"
    nstk::tmpl::parse $chunk
    nstk::tmpl::code "
     }"
}

# Repeat template chunk until the column name stays the same
nstk::tag::create group { chunk params } {

    set name [ns_set iget $params name]
    set column [ns_set iget $params column]
    nstk::tmpl::code "
     while {1} {"
    nstk::tmpl::parse $chunk
    nstk::tmpl::code "
       if { \$_row$name >= \${$name:rowcount} } { break }
       upvar 0 $name:\[expr \$_row$name + 1\] ${name}0
       if { \${${name}0($column)} != \$${name}($column) } { break }
       incr _row$name
       upvar 0 $name:\$_row$name $name
     }"
}

# Repeat a template chunk for each item in a list
nstk::tag::create list { chunk params } {

    set name [ns_set iget $params name]
    nstk::tmpl::code "
      for { set _row$name 0 } { \$_row$name < \[llength \$$name\] } { incr _row$name } {
        set $name:item \[lindex \$$name \$_row$name\]"
    nstk::tmpl::parse $chunk
    nstk::tmpl::code "}"
}

nstk::tag::create return { params } {

    nstk::tmpl::code "return"
}

nstk::tag::create continue { params } {

    nstk::tmpl::code "continue"
}

nstk::tag::create stop { params } {

    nstk::tmpl::code "nstk::tmpl::stop"
}

nstk::tag::create if { chunk params } {

    set condition ""
    set args ""
    set size [ns_set size $params]
    for { set i 0 } { $i < $size } { incr i } {
      append args [ns_set key $params $i] " "
    }
    set size [llength $args]
    for { set i 0 } { $i < $size } {} {
      set arg1 "\"[lindex $args $i]\""
      incr i
      set op [lindex $args $i]
      if { $op == "not" } {
        append condition "!"
        incr i
        set op [lindex $args $i]
      }
      incr i
      switch $op {
        gt {
          append condition "($arg1 > \"[lindex $args $i]\")"
          incr i
        }
        ge {
          append condition "($arg1 >= \"[lindex $args $i]\")"
          incr i
        }
        lt {
          append condition "($arg1 < \"[lindex $args $i]\")"
          incr i
        }
        le {
          append condition "($arg1 <= \"[lindex $args $i]\")"
          incr i
        }
        eq {
          append condition "(\[string equal $arg1 \"[lindex $args $i]\"\])"
          incr i
        }
        ne {
          append condition "(!\[string equal $arg1 \"[lindex $args $i]\"\])"
          incr i
        }
        match {
          append condition "(\[string match $arg1 \"[lindex $args $i]\"\])"
          incr i
        }
        regexp {
          append condition "(\[regexp -nocase $arg1 \"[lindex $args $i]\"\])"
          incr i
        }
        in {
          append condition "(\[lsearch -exact {[lrange $args $i end]} $arg1\] > -1)"
          set i $size
        }
        nil {
          regsub {@([a-zA-z0-9_]+)\.([a-zA-z0-9_:]+)@} $arg1 {\1(\2)} arg1
          regsub {@([a-zA-z0-9_:]+)@} $arg1 {\1} arg1
          append condition "(!\[info exists $arg1\])"
        }
        odd {
          append condition "(\[expr $arg1 % 2\])"
        }
        even {
          append condition "(!\[expr $arg1 % 2\])"
        }
        mod {
          append condition "(\[expr $arg1 % [lindex $args $i]\])"
          incr i
        }
        true {
          append condition "(\[nstk::true $arg1\])"
        }
        default {
          error "Unknown operator '$op' in <IF> tag: $args"
        }
      }
      if { $i >= $size } { break }
      switch [lindex $args $i] {
        and { append condition " && " }
        or { append condition " || " }
        default { error "Unknown junction '[lindex $args $i]' in <IF> tag: '$args'" }
      }
      incr i
    }
    nstk::tmpl::code "if \{ $condition \} \{"
    nstk::tmpl::parse $chunk
    nstk::tmpl::code "\}"
}

nstk::tag::create else { params } {

    nstk::tmpl::code "\} else \{"
}

