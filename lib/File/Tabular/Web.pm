package File::Tabular::Web; # documentation at bottom of file

our $VERSION = "0.20"; 

use strict;
use warnings;
no warnings 'uninitialized';
use locale;
use Carp;
use CGI;
use Template;
use POSIX 'strftime';
use List::Util      qw/min/;
use List::MoreUtils qw/uniq any all/;
use AppConfig       qw/:argcount/;
use File::Tabular 0.71;
use Search::QueryParser;


my %app_cache;
my %datafile_cache;      #  persistent data private to _cached_content


# Methods names starting with an '_' should not be overridden 
# in subclasses !


#======================================================================
#             MAIN ENTRY POINT (for modperl or cgi-bin)               #
#======================================================================


#----------------------------------------------------------------------
sub handler : method { 
#----------------------------------------------------------------------
  my $class = shift; # if under modperl, $_[0] will be the Apache2::RequestRec
  my $self;
  eval { $self = $class->_new(@_);  $self->_dispatch_request; 1;}
    or do {
      $self ||= bless {}, $class;  # fake object if the new() method failed
      $self->{msg} = "<b><font color='red'>ERROR</font></b> : $@";
      $self->{view} = 'msg';

      # try displaying through msg view..
      eval {$self->display}
        or do { # .. or else fallback with simple HTML page
          my $content = "<html>$self->{msg}</html>\n";
          if (ref($_[0]) =~ /^Apache2/) { # if under mod_perl
            $_[0]->print($content)
          }
          else {
            print "Content-type: text/html\n\n$content";
          }
        };
    };

  return 0; # Apache2::Const::OK;
}


#======================================================================
#     METHODS FOR CREATING / INITIALIZING "APPLICATION" HASHREFS      #
#======================================================================

#----------------------------------------------------------------------
sub _app_new { # creates a new application hashref (not an object)
#----------------------------------------------------------------------
  my ($class, $config_file) = @_;
  my $app = {};

  # application name and directory : defaults from the name of config file
#  @{$app}{qw(name dir suffix)} = fileparse($config_file, qr/\.[^.]*$/);
  @{$app}{qw(dir name)} = ($config_file =~ m[^(.+[/\\])(.+?)(?:\.[^.]*)$]);

  # read the config file
  $app->{cfg} = $class->_app_read_config($config_file);

  my $tmp; # predeclare $tmp so that it can be used in "and" clauses

  # application directory
  $tmp = $app->{cfg}->get('application_dir')  and do {
    $tmp =~ s{[^/\\]$}{/}; # add trailing "/" to dir if necessary
    $app->{dir} = $tmp;
  };

  # application name
  $tmp = $app->{cfg}->get('application_name') and $app->{name} = $tmp;

  # data file
  $tmp = $app->{cfg}->get('application_data');
  $app->{data_file} = $app->{dir} . ($tmp || "$app->{name}.txt");

  # application class
  $tmp = $app->{cfg}->get('application_class') and do {
    eval "require $tmp" or die $@; # dynamically load the requested code
    $tmp->isa($class) or die "$tmp is not a $class";
    $app->{class} = $tmp;
  };
  $app->{class} ||= $class; # default if not specified in config

  return $app;
}

#----------------------------------------------------------------------
sub _app_read_config { # read configuration file through Appconfig
#----------------------------------------------------------------------
  my ($class, $config_file) = @_;

  # error handler : die for all errors except "no such variable"
  my $error_func = sub { 
    my $fmt = shift;
    die sprintf("AppConfig : $fmt\n", @_) 
      unless $fmt =~ /no such variable/; 
  };

  # create AppConfig object (options documented in L<AppConfig::State>)
  my $cfg = AppConfig->new({ 
    CASE   => 1,                         # case-sensitive
    CREATE => 1,                         # accept dynamic creation of variables
    ERROR  => $error_func,               # specific error handler
    GLOBAL => {ARGCOUNT => ARGCOUNT_ONE},# default option for undefined vars
  });

  # define specific options for some variables
  # NOTE: fields_upload is not used here, but by F::T::Attachments
  foreach my $hash_var (qw/fields_default fields_time fields_upload/) {
    $cfg->define($hash_var => {ARGCOUNT => ARGCOUNT_HASH});
  }
  $cfg->define(fieldSep  => {DEFAULT => "|"});

  # read the configuration file
  $cfg->file($config_file); # or croak "AppConfig: open $config_file: $^E";
  # BUG : AppConfig does not return any error code if ->file(..) fails !!

  return $cfg;
}



#----------------------------------------------------------------------
sub app_initialize {
#----------------------------------------------------------------------
  # NOTE: this method is called after instance creation and therefore
  # takes into account the subclass which may have been given in the
  # config file.

  my ($self)   = @_;
  my $app      = $self->{app};
  my ($last_subdir) = ($app->{dir} =~ m[^.*[/\\](.+)[/\\]?$]);
  my $default  = $self->app_tmpl_default_dir;

  # directories to search for Templates
  my @tmpl_dirs = grep {-d} ($app->{cfg}->get("template_dir"), 
                             $app->{dir}, 
                             "$default/$last_subdir",
                             $default,
                             "$default/default",
                            );

  # initialize template toolkit object
  $app->{tmpl} = Template->new({
    INCLUDE_PATH => \@tmpl_dirs,
    FILTERS      => $self->app_tmpl_filters,
    EVAL_PERL    => 1,
   })
    or die Template->error;

   # special fields : time of last modif, author of last modif
  $app->{time_fields} = $app->{cfg}->get('fields_time');
  $app->{user_field}  = $app->{cfg}->get('fields_user');
}


#----------------------------------------------------------------------
sub app_tmpl_default_dir { # default; override in subclasses
#----------------------------------------------------------------------
  my ($self) = @_;

  return "$self->{server_root}/lib/tmpl/ftw";
}


#----------------------------------------------------------------------
sub app_tmpl_filters { # default; override in subclasses
#----------------------------------------------------------------------
  my ($self) = @_;
  my $cfg = $self->{app}{cfg};
  my $ini_marker = $cfg->get('preMatch');
  my $end_marker = $cfg->get('postMatch');

  # no highlight filters without pre/postMatch
  $ini_marker && $end_marker or return {}; 

  my $HL_class   = $cfg->get('highlightClass') || "HL";
  my $regex      = qr/\Q$ini_marker\E(.*?)\Q$end_marker\E/s;

  my $filters = {
    highlight => sub {
      my $text = shift;
      $text =~ s[$regex][<span class="$HL_class">$1</span>]g;
      return $text;
    },
    unhighlight => sub {
      my $text = shift;
      $text =~ s[$regex][$1]g;
      return $text;
    }
   };
  return $filters;
}




#----------------------------------------------------------------------
sub app_phases_definitions {
#----------------------------------------------------------------------
  my $class = shift;

# PHASES DEFINITIONS TABLE : each single letter is expanded into 
# optional methods for data preparation, data operation, and view.
# It is also possible to differentiate between GET and POST requests.
  return (

    A => # prepare a new record for adding
      {GET  => {pre => 'empty_record',                  view => 'modif'},
       POST => {pre => 'empty_record', op => 'update'                  }  },

    D => # delete record
      {pre => 'search_key', op => 'delete'                                },

    H => # display home page
      {                                                 view => 'home'    },

    L => # display "long" view of one single record
      {pre => 'search_key',                             view => 'long'    },

    M => # modif: GET displays the form, POST performs the update
      {GET  => {pre => 'search_key',                    view => 'modif'},
       POST => {pre => 'search_key', op => 'update'                }  },

    S => # search and display "short" view
      {pre => 'search', op => 'sort_and_slice',         view => 'short'   },

    X => # display all records in "download view" (mnemonic: eXtract)
      {pre => 'prepare_download',                       view => 'download'},

   );
}



#======================================================================
#           METHODS FOR INSTANCE CREATION / INITIALIZATION            #
#======================================================================

#----------------------------------------------------------------------
sub _new { # creates a new instance of a request object
#----------------------------------------------------------------------
  my $class = shift; # if under modperl, $_[0] will be the Apache2::RequestRec
  my $self = {};
  my $path;

  # if under mod_perl, we got an Apache2::RequestRec as second arg
  if (ref($_[0]) =~ /^Apache2/) {
    $self->{modperl}     = $_[0];
    $self->{server_root} = Apache2::ServerUtil::server_root();
    $self->{user}        = $self->{modperl}->user || "Anonymous";
    $self->{url}         = $self->{modperl}->uri;
    $self->{method}      = $self->{modperl}->method;
    $path                = $self->{modperl}->filename;

    require APR::Request::Apache2;
    $self->{APR_request} = APR::Request::Apache2->handle($self->{modperl});
  }
  else { # create the CGI instance
    $self->{cgi}         = CGI->new(@_);
    # server_root: no definite info. We guess it is one level above doc_root
    $self->{server_root} = ($ENV{DOCUMENT_ROOT} =~ m[(.*)[/\\]])[0];
    $self->{user}        = $self->{cgi}->remote_user || "Anonymous";
    $self->{url}         = $self->{cgi}->url(-path => 1);
    $self->{method}      = $self->{cgi}->request_method;
    $path                = $self->{cgi}->path_translated;
  }

  # get file last modification time
  my $mtime = (stat $path)[9] or die "couldn't stat $path";
  my $cache_entry = $app_cache{$path};
  my $app_initialized = $cache_entry && $cache_entry->{mtime} == $mtime;
  if (not $app_initialized) {
    $app_cache{$path} = {mtime   => $mtime, 
                         content => $class->_app_new($path)};
  }
  $self->{app} = $app_cache{$path}->{content};
  $self->{cfg} = $self->{app}{cfg}; # shortcut

  # bless the request obj into the application class, initialize and return
  bless $self, $self->{app}{class};
  $app_initialized or $self->app_initialize; # must happen after "bless"
  $self->initialize;
  return $self;
}


#----------------------------------------------------------------------
sub initialize { # setup params from config and/or CGI params
#----------------------------------------------------------------------
  my $self = shift;

  # default values
  $self->{max}     = $self->param('max')   || 500;
  $self->{count}   = $self->param('count') ||  50;
  $self->{orderBy} = $self->param('orderBy') 
                  || $self->param('sortBy'); # for backwards compatibility

  return $self;
}


#----------------------------------------------------------------------
sub _setup_phases { # decide about next phases
#----------------------------------------------------------------------
  my $self = shift;

  # get all phases definitions (expansions of single-letter param)
  my %request_phases = $self->app_phases_definitions;

  # find out which single-letter was requested
  my @letters = grep {defined $request_phases{$_}} uniq $self->param;

  # cannot ask for several operations at once
  @letters <= 1 or die "conflict in request: " . join(" / ", @letters);

  # by default : homepage
  my $letter = $letters[0] || "H"; 

  # argument passed to operation
  my $letter_arg = $self->param($letters[0]);

  # special case : with POST requests, we want to also consider the ?A or ?M=..
  # or ?D=.. from the query string
  if (not @letters and $self->{method} eq 'POST') {
    my ($target, $method) = 
      $self->{modperl} ? ($self->{APR_request}, "args"     )
                       : ($self->{cgi},         "url_param");
    for my $try_letter (qw/A M D/) {
      $letter_arg = $target->$method($try_letter);
      $letter = $try_letter and last if defined($letter_arg);
    }
  }

  # setup info in $self according to the chosen letter
  my $entry     = $request_phases{$letter};
  my $phases    = $entry->{$self->{method}} || $entry;
  $self->{view} = $self->param('V') || $phases->{view};
  $self->{pre}  = $phases->{pre};
  $self->{op}   = $phases->{op};

  return $letter_arg;
}


#----------------------------------------------------------------------
sub open_data { # open File::Tabular object on data file
#----------------------------------------------------------------------
  my $self = shift;

  # parameters for opening the file
  my $open_src = $self->{app}{data_file};
  my $mtime    = (stat $open_src)[9] or die "couldn't stat $open_src";

  # text version of modified time for templates
  if (my $fmt = $self->{cfg}->get('application_mtime')) {
    $self->{mtime} = strftime($fmt, localtime($mtime));
  }

  my $open_mode = ($self->{op} =~ /delete|update/) ? "+<" : "<";

  # application option : use in-memory cache only for read operations
  if ($self->{cfg}->get('application_useFileCache') 
        && $open_mode eq '<') { 
    my $cache_entry = $datafile_cache{$open_src};
    unless ($cache_entry && $cache_entry->{mtime} == $mtime) {
      open my $fh, $open_src or die "open $open_src : $^E";
      local $/ = undef;
      my $content = <$fh>;	# slurps the whole file into memory
      close $fh;
      $datafile_cache{$open_src} = {mtime   => $mtime, 
                                    content => \$content };
    }
    $open_src = $cache_entry->{content}; # ref to in-memory content
  }

  # set up options for creating File::Tabular object
  my %options;
  foreach (qw/preMatch postMatch avoidMatchKey fieldSep recordSep/) {
    $options{$_} = $self->{cfg}->get($_);
  }
  $options{autoNumField} = $self->{cfg}->get('fields_autoNum');
  my $jFile = $self->{cfg}->get('journal');
  $options{journal} = "$self->{app}{dir}$jFile" if $jFile;

  # create File::Tabular object
  $self->{data} = new File::Tabular($open_mode, $open_src, \%options);
}


#======================================================================
#               PUBLIC METHODS CALLABLE FROM TEMPLATES                #
#======================================================================


#----------------------------------------------------------------------
sub param { 
#----------------------------------------------------------------------
  my ($self, $param_name) = @_; # $param_name might be undef

  # Unified way to get to param() method in the underlying layer.
  # On POST requests, CGI->param(..) only returns body params, while
  # APR::Request->param(..) returns both query string and body params;
  # here we only want body params, so we must call another method (body).
  my $target = $self->{modperl} ? $self->{APR_request} : $self->{cgi};
  my $param_method 
    = ($self->{modperl} && $self->{method} eq 'POST') ? 'body' : 'param';
  my @vals = defined($param_name) ? $target->$param_method($param_name)
                                  : $target->$param_method();

  # if no arg, just return the list of param names
  return @vals if not defined $param_name;

  # otherwise, first check in "fixed" section in config
  my $val = $self->{cfg}->get("fixed_$param_name");
  return $val if $val;

  # then check in parameters to this request (flattened into a scalar)
  if (@vals) {
    $val = join(' ', @vals);    # join multiple values
    $val =~ s/^\s+//;           # remove initial spaces
    $val =~ s/\s+$//;           # remove final spaces
    return $val;
  }

  # finally check in "default" section in config
  return $self->{cfg}->get("default_$param_name");
}


#----------------------------------------------------------------------
sub can_do { # can be called from templates; $record is optional
#----------------------------------------------------------------------
  my ($self, $action, $record) = @_;

  my $allow  = $self->{cfg}->get("permissions_$action");
  my $deny = $self->{cfg}->get("permissions_no_$action");

  # some permissions are granted by default to everybody
  $allow ||= "*" if $action =~ /^(read|search|download)$/;

  for ($allow, $deny) {
    $_ or next;                   # no acl list => nothing to do
    $_ = $self->user_match($_)    #    if acl list matches user name
       ||(   /\$(\S+)\b/i         # or if acl list contains a field name ...
	  && defined($record)                   # ... and got a specific record
          && defined($record->{$1})             # ... and field is defined
	  && $self->user_match($record->{$1})); # ... and field content matches
  }

  return $allow && !$deny;
}



#======================================================================
#                 REQUEST HANDLING : GENERAL METHODS                  #
#======================================================================


#----------------------------------------------------------------------
sub _dispatch_request { # go through phases and choose appropriate handling
#----------------------------------------------------------------------
  my $self = shift;
  my $method;

  # determine phases from single-letter param; keep arg value from that letter
  my $letter_arg = $self->_setup_phases;

  # data access
  $self->open_data;

  # data preparation : invoke method if any, passing the arg saved above
  $method = $self->{pre} and $self->$method($letter_arg);

  # data manipulation : invoke method if any
  $method = $self->{op} and $self->$method;

  # force message view if there is a message
  $self->{view} = 'msg' if $self->{msg}; 

  # print the output
  $self->display;
}


#----------------------------------------------------------------------
sub display { # display results in the requested view
#----------------------------------------------------------------------
  my ($self) = @_;
  my $view = $self->{view} or die "display : no view";


  # name of the template for this view
  my $default_tmpl = $view eq 'download' ? "download.tt"
                                         : "$self->{app}{name}_$view.tt";
  my $tmpl_name = $self->{cfg}->get("template_$view") || $default_tmpl;

  # override template toolkit's failsafe counter for while loops
  # in case of download action
  local $Template::Directive::WHILE_MAX = 50000 if $view eq 'download';

  # call that template
  my $body;
  my $vars = {self => $self, found => $self->{results}};
  $self->{app}{tmpl}->process($tmpl_name, $vars, \$body)
    or die $self->{app}{tmpl}->error();

  $self->_emit_page(\$body);
}


#----------------------------------------------------------------------
sub _emit_page {
#----------------------------------------------------------------------
  my ($self, $body_ref) = @_;

  # print headers and body
  my $length   = length $$body_ref;
  my $modified = $self->{data}->stat->{mtime};
  if ($self->{modperl}) {
    $self->{modperl}->content_type('text/html');
    $self->{modperl}->set_last_modified($modified);
    $self->{modperl}->set_content_length($length);
    $self->{modperl}->headers_out->add(Expires => 0);
    $self->{modperl}->print($$body_ref);
  }
  else {
    my $CRLF = "\015\012";
    print "Content-type: text/html$CRLF"
        . "Content-length: $length$CRLF"
        . "Last-modified: $modified$CRLF"
        . "Expires: 0$CRLF"
        . "$CRLF"
        . $$body_ref;
  }
}



#======================================================================
#                 REQUEST HANDLING : SEARCH METHODS                   #
#======================================================================


#----------------------------------------------------------------------
sub search_key { # search by record key
#----------------------------------------------------------------------
  my ($self, $key) = @_;
  $self->can_do("read") or 
    die "no 'read' permission for $self->{user}";
  $key or die "search_key : no key!";
  $key =~ s/<.*?>//g; # remove any markup (maybe inserted by pre/postMatch)

  my $query = "K_E_Y:$key";

  my ($records, $lineNumbers) = $self->{data}->fetchall(where => $query);
  my $count = @$records;
  $self->{results}{count}       = $count;
  $self->{results}{records}     = $records;
  $self->{results}{lineNumbers} = $lineNumbers;
}



#----------------------------------------------------------------------
sub search { # search records and display results
#----------------------------------------------------------------------
  my ($self, $search_string) = @_;

  # check permissions
  $self->can_do('search') or 
    die "no 'search' permission for $self->{user}";

  $self->{search_string_orig} = $search_string;
  $self->before_search;
  $self->log_search;

  $self->{results}{count}       = 0;
  $self->{results}{records}     = [];
  $self->{results}{lineNumbers} = [];

  return if $self->{search_string} =~ /^\s*$/; # no query, no results

  my $qp = new Search::QueryParser;

  # compile query with an implicit '+' prefix in front of every item 
  my $parsedQ = $qp->parse($self->{search_string}, '+') or 
    die "error parsing query : $self->{search_string}";

  my $filter;

  eval {$filter = $self->{data}->compileFilter($parsedQ);} or
    die("error in query : $@ ," . $qp->unparse($parsedQ) 
                                  . " ($self->{search_string})");

  # perform the search
  @{$self->{results}}{qw(records lineNumbers)} = 
    $self->{data}->fetchall(where => $filter);
  $self->{results}{count} = @{$self->{results}{records}};

  # VERY CHEAP way of generating regex for highlighting results
  my @words_queried = uniq(grep {length($_)>2} $self->words_queried);
  $self->{results}{wordsQueried} = join "|", @words_queried;
}


#----------------------------------------------------------------------
sub before_search {
#----------------------------------------------------------------------
  my ($self) = @_;
  $self->{search_string} = $self->{search_string_orig} || "";
  return $self;
}



#----------------------------------------------------------------------
sub sort_and_slice { # sort results, then just keep the desired slice
#----------------------------------------------------------------------
  my $self = shift;

  delete $self->{results}{lineNumbers}; # not going to use those

  # sort results
  if ($self->{orderBy}) {
    eval {
      my $cmpfunc = $self->{data}->ht->cmp($self->{orderBy});
      $self->{results}{records} = [sort $cmpfunc @{$self->{results}{records}}];
    }
      or die "orderBy : $@";
  }

  # restrict to the desired slice
  my $start_record = $self->param('start') || ($self->{results}{count} ? 1 : 0);
  my $end_record   = min($start_record + $self->{count} - 1,
			 $self->{results}{count});
  die "illegal start value : $start_record" if $start_record > $end_record;
  $self->{results}{records} = $self->{results}{count}  
    ? [ @{$self->{results}{records}}[$start_record-1 ... $end_record-1] ]
    : [];

  # check read permission on records (looping over records only if necessary)
  my $must_loop_on_records # true if  permission depends on record fields
    =  (($self->{cfg}->get("permissions_read") || "")    =~ /\$/)
    || (($self->{cfg}->get("permissions_no_read") || "") =~ /\$/);
  if ($must_loop_on_records) {
    foreach my $record (@{$self->{results}{records}}) {
      $self->can_do('read', $record) 
        or die "no 'read' permission for $self->{user}";
    }
  }
  else { # no need for a loop
    $self->can_do('read') 
      or die "no 'read' permission for $self->{user}";
  }

  # for user display : record numbers start with 1, not 0 
  $self->{results}{start} = $start_record;
  $self->{results}{end}   = $end_record;


  # links to previous/next slice
  my $prev_idx = $start_record - $self->{count};
     $prev_idx = 1 if $prev_idx < 1;
  $self->{results}{prev_link} = $self->_url_for_next_slice($prev_idx)
    if $start_record > 1;
  my $next_idx = $start_record + $self->{count};
  $self->{results}{next_link} = $self->_url_for_next_slice($next_idx)
    if $next_idx <= $self->{results}{count};
}


#----------------------------------------------------------------------
sub _url_for_next_slice { 
#----------------------------------------------------------------------
  my ($self, $start) = @_;

  my $url = "?" . join "&", $self->params_for_next_slice($start);

  # uri encoding
  $url =~ s/([^;\/?:@&=\$,A-Z0-9\-_.!~*'() ])/sprintf("%%%02X", ord($1))/ige;

  return $url;
}


#----------------------------------------------------------------------
sub params_for_next_slice { 
#----------------------------------------------------------------------
  my ($self, $start) = @_;

  # need request object to invoke native param() method
  my $req = $self->{APR_request} || $self->{cgi}; 

  my @params = ("S=$self->{search_string_orig}", "start=$start");
  push @params, "orderBy=$self->{orderBy}" if $req->param('orderBy');
  push @params, "count=$self->{count}"     if $req->param('count');

  return @params;
}


#----------------------------------------------------------------------
sub words_queried {
#----------------------------------------------------------------------
  my $self = shift;
  return ($self->{search_string_orig} =~ m([\w/]+)g);
}



#----------------------------------------------------------------------
sub log_search {
#----------------------------------------------------------------------
  my $self = shift;
  return if not $self->{logger};

  my $msg = "[$self->{search_string}] $self->{user}";
  $self->{logger}->info($msg);
}


#======================================================================
#                 REQUEST HANDLING : UPDATE METHODS                   #
#======================================================================


#----------------------------------------------------------------------
sub empty_record { # to be displayed in "modif" view (when adding)
#----------------------------------------------------------------------
  my ($self) = @_;

  $self->can_do("add") or 
    die "no 'add' permission for $self->{user}";

  # build a record and insert default values
  my $record = $self->{data}->ht->new;
  my $defaults = $self->{cfg}->get("fields_default");
  if (my $auto_num = $self->{data}{autoNumField}) {
    $defaults->{$auto_num} ||= $self->{data}{autoNumChar};
  }
  $record->{$_} = $defaults->{$_} foreach $self->{data}->headers;

  $self->{results} = {count => 1, records => [$record], lineNumbers => [-1]};
}


#----------------------------------------------------------------------
sub update {
#----------------------------------------------------------------------
  my ($self) = @_;

  # check if there is one record to update
  my $found  = $self->{results};
  $found->{count} == 1 or die "unexpected number of records to update";

  # gather some info
  my $record     = $found->{records}[0];
  my $line_nb    = $found->{lineNumbers}[0]; 
  my $is_adding  = $line_nb == -1;
  my $permission = $is_adding ? 'add' : 'modif';

  # check if user has permission
  $self->can_do($permission, $record)
    or die "No permission '$permission' for $self->{user}";

  # if adding, must make sure to read all rows so that autonum gets updated
  if ($is_adding &&  $self->{cfg}->get('fields_autoNum')) {
    while ($self->{data}->fetchrow) {} 
  }

  # call hook before update
  $self->before_update($record);

  # prepare message to user
  my @headers = $self->{data}->headers;
  my $data_line = join("|", @{$record}{@headers});
  my ($msg, $id) = $is_adding ? ("Created", $self->{data}{autoNum})
                              : ("Updated", $self->key($record));
  $self->{msg} .= "<br>$msg:<br>"
               .  "<a href='?S=K_E_Y:$id'>Record $id</a>: $data_line<br>";

  # do the update
  my $to_delete = $is_adding ? 0         # no previous line to delete
                             : 1;        # replace previous line
  eval {$self->{data}->splices($line_nb, $to_delete, $record)} or do {
    my $err = $@;
    $self->rollback_update($record);
    die $err;
  };

  # call hook after update
  $self->after_update($record);
}


#----------------------------------------------------------------------
sub before_update { # 
#----------------------------------------------------------------------
  my ($self, $record) = @_;

  # copy defined params into record ..
  my $key_field = $self->param($self->key_field);
  foreach my $field ($self->{data}->headers) {
    my $val = $self->param($field);
    next if not defined $val;
    if ($field eq $key_field and $val ne $self->key($record)) {
      die "supplied key $val does not match record key";
    }
    $record->{$field} = $val;
  }

  # force username into user field (if any)
  my $user_field = $self->{app}{user_field};
  $record->{$user_field} = $self->{user} if $user_field;

  # force current time or date into time fields (if any)
  while (my ($k, $fmt) = each %{$self->{app}{time_fields}}) {
    $record->{$k} = strftime($fmt, localtime);
  }
}


sub after_update    {} # override in subclasses
sub rollback_update {} # override in subclasses


#======================================================================
#                 REQUEST HANDLING : DELETE METHODS                   #
#======================================================================

#----------------------------------------------------------------------
sub delete {
#----------------------------------------------------------------------
  my $self = shift;

  # check if there is one record to update
  my $found = $self->{results};
  $found->{count} == 1 or die "unexpected number of records to delete";

  # gather some info
  my $record     = $found->{records}[0];
  my $line_nb    = $found->{lineNumbers}[0]; 

  # check if user has permission
  $self->can_do("delete", $record) 
    or die "No permission 'delete' for $self->{user}";

  # call hook before delete
  $self->before_delete($record);

  # do the deletion
  $self->{data}->splices($line_nb, 1, undef);

  # message to user
  my @headers = $self->{data}->headers;
  my @values = @{$record}{@headers};
  $self->{msg} = "Deleted:<br>" . join("|", @values);

  # call hook after delete
  $self->after_delete($record);
}


sub before_delete {} # override in subclasses
sub after_delete  {} # override in subclasses


#======================================================================
#                       MISCELLANEOUS METHODS                         #
#======================================================================



#----------------------------------------------------------------------
sub prepare_download {
#----------------------------------------------------------------------
  my ($self, $which) = @_;
  $self->can_do('download')
    or die "No permission 'download' for $self->{user}";
}


#----------------------------------------------------------------------
sub print_help {
#----------------------------------------------------------------------
  print "sorry, no help at the moment";
}



#----------------------------------------------------------------------
sub user_match {
#----------------------------------------------------------------------
  my ($self, $access_control_list) = @_;

  # success if the list contains '*' or the current username
  return ($access_control_list =~ /\*|\b\Q$self->{user}\E\b/i);
}


#----------------------------------------------------------------------
sub key_field { 
#----------------------------------------------------------------------
  my ($self) = @_;
  return ($self->{data}->headers)[0];
}


#----------------------------------------------------------------------
sub key { # returns the value in the first field of the record
#----------------------------------------------------------------------
  my ($self, $record) = @_;

  # optimized version, breaking encapsulation of File::Tabular
  return (tied %$record)->[1];

  # going through official API would be : return $record->{$self->key_field};
}

1;


__END__

=head1 NAME

File::Tabular::Web - turn a tabular file into a web application

=head1 SYNOPSIS

=over

=item configure the http server (here with modperl)

  <LocationMatch "\.ftw$">
    SetHandler modperl
    PerlResponseHandler File::Tabular::Web
  </LocationMatch>

=item generate a CRUD application for one tabular file (scaffolding)

  cp some/data.txt /path/to/http/htdocs/some/data.txt
  perl ftw_new_app.pl /path/to/http/htdocs/some/data.txt

=item use the application

  http://myServer/some/data.ftw

=item customize

  # change some configuration options
  edit /path/to/http/htdocs/some/data.ftw 
  
  # change the views
  edit /path/to/http/htdocs/some/{data_short.tt,data_long.tt,data_edit.tt}

=back

=head1 DESCRIPTION

=head2 Introduction

This is a simple Apache web application framework based on
L<File::Tabular|File::Tabular> and
L<Search::QueryParser|Search::QueryParser>.  The framework offers
builtin services for searching, displaying and updating a flat tabular
datafile, possibly with attached documents (see
L<File::Tabular::Web::Attachments|File::Tabular::Web::Attachments> and 
L<File::Tabular::Web::Attachments::Indexed|File::Tabular::Web::Attachments::Indexed>).

The strong point of C<File::Tabular::Web> is that it is built
around a search engine designed from the start for Web 
requests : by default it searches for complete words, spanning
all data fields. However, you can easily write queries that
look in specific fields, using regular expressions, boolean
combinations, arithmetic operators, etc.
So if you are looking for simplicity and speed of development,
rather than speed of execution, then you may have found a convenient
tool. 

We use it intensively in our Intranet for managing 
lists of people, rooms, meetings, internet pointers, etc., and even
for more sensitive information like lists of payments or 
the archived judgements (minutes) of Geneva courts.
Of course this is slower that a real database, 
but for data up to 10MB/50000 records, the difference
is hardly noticeable. On the other side, ease of
development and deployment and ease of importing/exporting
data proved to be highly valuable assets.


=head2 Building an application

To build an application, all you need to do is :

=over

=item *

Insert the data (a tabular .txt file) somewhere
in your Apache F<htdocs> tree.

=item *

Run the helper script L<ftw_new_app.pl>, which
automatically builds configuration and template files.
The new URL becomes immediately
active, without webserver configuration nor restart, 
so you already have a "scaffolding" 
application for searching, displaying, and maybe
edit the data.


=item *

If necessary, tune various options in the configuration file,
and customize the template files for presenting the data
according to your needs.

=back

In most cases, those steps will be sufficient, so
they can be performed by a webmaster without Perl
knowledge.

For more advanced uses, application-specific Perl 
subclasses  can be
hooked up into the framework for performing particular tasks.
See for example the companion
L<File::Tabular::Web::Attachments|File::Tabular::Web::Attachments>
module, which provides services for attaching documents
and indexing them through  L<Search::Indexer|Search::Indexer>,
therefore providing a mini-framework for storing electronic documents.


=head1 QUICKSTART


=head2 Apache configuration

C<File::Tabular::Web> is designed so that it can be
installed once and for all in your Apache configuration.
Then all I<applications> can be added or modified
on the fly, without restarting the server.

First choose a file extension for your C<File::Tabular::Web> 
applications; in the examples below we assume it to be C<.ftw>.
Then configure your Apache server in one of the ways described
below.


=head3 Configuration as a mod_perl handler

If you have mod_perl, the easiest way is to declare
it as a mod_perl handler associated to C<.ftw> URLs.
Edit your F<perl.conf> as follows :

  <LocationMatch "\.ftw$">
    SetHandler modperl
    PerlResponseHandler File::Tabular::Web
  </LocationMatch>


=head3 Configuration as a cgi-bin script

Create an executable file in F<cgi-bin> directory, 
named C<ftw>, and containing

   #!/path/to/perl
   use File::Tabular::Web;
   File::Tabular::Web->handler;

Then you can acces your applications as

  http://my.server/cgi-bin/ftw/path/to/my/app.ftw


=head4 Implicit call of the script through mod_actions

If your Apache has the C<mod_actions> module
(most installations have it), then it
is convenient to add the following directives
in F<httpd.conf> :

  Action file-tabular-web /cgi-bin/ftw 
  AddHandler file-tabular-web .ftw

Now any file ending with ".ftw" in your htdocs tree will be treated as
a File::Tabular::Web application. In other words,
instead of 

  http://my.server/cgi-bin/ftw/path/to/my/app.ftw

you can use URL

  http://my.server/path/to/my/app.ftw


As already explained, C<.ftw> is just an arbitrary convention
and can be replaced by any other suffix.
Similarly, the C<file-tabular-web> handler name can be arbitrarily 
replaced by another name.



=head3 Configuration as a fastcgi script

[probably works like cgi-bin; not tested yet]




=head2 Setting up a particular application

We'll take for example a simple people directory application.


=over

=item *

First create directory F<htdocs/people>.

=item *

Let's assume that you already have a list of people,
in a spreadsheet or a database.
Export that list into a flat text file named
F<htdocs/people/dir.txt>.
If you export from an Excel Spreadsheet, do NOT export as CSV format ; 
choose "text (tab-separated)" instead. The datafile should contain
one line per record, with a character like '|' or TAB as field 
separator, and field names on the first line 
(see L<File::Tabular|File::Tabular> for details).


=item *

Run the helper script

  perl ftw_new_app.pl --fieldSep \\t htdocs/people/dir.txt

This will create in the same directory a configuration file C<dir.ftw>,
and a collection of HTML templates C<dir_short.tt>, C<dir_long.tt>,
C<dir_modif.tt>, etc. The C<--fieldSep> option specifies which
character acts as field separator (the default is '|');
other option are available, see

  perl ftw_new_app.pl --help

for a list.

=item *

The URL C<http:://your.web.server/people/dir.ftw>
is now available to access the application.
You may first test the default layout, and then customize
the templates to suit your needs.

=back

Note : initially all files are placed in the same directory, because
it is simple and convenient; however, data and templates files
are not really web resources and therefore theoretically should not 
belong to the htdocs tree. If you want a more structured architecture,
you may move these files to a different location, and specify
within the configuration how to find them (see instructions below).


=head1 WEB API

=head2 Entry points

Various entry points into the application 
(searching, editing, etc.) are
chosen by single-letter arguments :


=head3 H

  http://myServer/some/app.ftw?H

Displays the homepage of the application (through the C<home> view).
This is the default entry point, i.e. equivalent to 

  http://myServer/some/app.ftw

=head3 S

  http://myServer/some/app.ftw?S=<criteria>

Searches records matching the specified criteria, and displays 
a short summary of each record (through the C<short> view).
Here are some example of search criteria :

  word1 word2 word3                 # records containing these 3 words anywhere
  +word1 +word2 +word3              # idem
  word1 word2 -word3                # containing word1 and word2 but not word3
  word1 AND (word2 OR word3)        # obvious
  "word1 word2 word3"               # sequence
  word*                             # word completion
  field1:word1 field2:word2         # restricted by field
  field1 == val1  field2 > val2     # relational operators (will inspect the
                                    #   shape of supplied values to decide
                                    #   about string/numeric/date comparisons)
  field~regex                       # regex

See L<Search::QueryParser> and L<File::Tabular> for 
more details.

Additional parameters may control sorting and pagination. Ex:

  ?S=word&orderBy=birthdate:-d.m.y,lastname:alpha&count=20&start=40

=over

=item count

How many items to display on one page. Default is 50.

=item start

Index within the list of results, telling
which is the first record to display (basis is 0).

=item orderBy

How to sort results. This may be one or several field
names, possibly followed by a specification
like C<:num> or C<:-alpha>.
Precise syntax is documented in
L<Hash::Type/cmp>.


=item max

Maximum number of records retrieved in a search (records
beyond that number will be dropped).


=back


=head3 L

  http://myServer/some/app.ftw?L=<key>

Finds the record with the given key and displays it
in detail through the C<long> view.


=head3 M

  http://myServer/some/app.ftw?M=key

If called with method GET, finds the record with the given key and 
displays it through the
C<modif> view (typically this view will be an HTML form).

If called with method POST, 
finds the record with the given key
and updates it with given field names and values.
After update, displays an update message through the C<msg> view.

=head3 A

  http://myServer/some/app.ftw?A

If called with method GET, displays a form for creating 
a new record, through the 
C<modif> view. Fields may be pre-filled by default values
given in the configuration file.

If called with method POST, 
creates a new record, with values given by the submitted form.
After record creation, displays an update message through the C<msg> view.

=head3 D

  http://myServer/some/app.ftw?D=<key>

Deletes record with the given key.
After deletion, displays an update message through the C<msg> view.


=head3 X

  http://myServer/some/app.ftw?X

Display all records throught the C<download> view
(mnemonic : eXtract)


=head2 Additional parameters

=head3 V

Name of the view (i.e. template) that will be used 
instead of the default one.
For example, assuming that the application
has defined a C<print> view, we can call that view through

  http://myServer/some/app.ftw?S=<criteria>&V=print



=head1 WRITING TEMPLATES

This section assumes that you already know how to write
templates for the Template Toolkit (see L<Template>).

The path for searching templates includes

=over

=item *

the application directory
(where the configuration file resides) 

=item *

the directory specified within the configuration file by parameter
C<< [template]dir >>

=item *

some default directories: 
  C<< <server_root>/lib/tmpl/ftw/<application_name> >>,
  C<< <server_root>/lib/tmpl/ftw/<default> >>,
  C<< <server_root>/lib/tmpl/ftw >>.


=back



=head2 Values passed to templates

=over

=item C<self>

handle to the C<File::Tabular::Web> object; from there you can access
C<self.url> (URL of the application), 
C<self.server_root> (server root directory), 
C<self.cfg> (configuration information, an L<AppConfig|AppConfig> object), 
C<self.mtime> (modification time of the data file),
C<self.modperl> or C<self.cgi>, 
and C<self.msg> (last message). You can also 
call methods L</can_do> or L</param>, like for example

  [% IF self.can_do('add') %]
     <a href="?A">Add a new record</a>
  [% END # IF %]


or 

  [% self.param('myFancyParam') %]

=item C<found>

structure containing the results of a search. 
Fields within this structure are :

=over

=item C<count>

how many records were retrieved

=item C<records>

arrayref containing a slice of records

=item C<start>

index of first record in the returned slice

=item C<end>

index of last record in the returned slice

=item C<next_link>

href link to the next slice of results (if any)

=item C<prev_link>

href link to the previous slice of results (if any)

=back


=back



=head2 Using relative URLS


All pages generated by the application have the same URL;
query parameters control which page will be displayed.
Therefore all internal links can just start with a question
mark : the browser will recognize that this is a relative
link to the same URL, with a different query string.
So within templates we can write simple links like

  <a href="?H">Homepage</a>
  <a href="?S=*">See all records</a>
  <a href="?A">Add a new record</a>
  [% FOREACH record IN found.records %]
    <a href="?M=[% record.Id %]">Modify this record</a>
  [% END # FOREACH  %]


=head2 Forms

=head3 Data input

A typical form for updating or adding a record will look like

  <form method="POST">
   First Name <input name="firstname" value="[% record.firstname %]"><br>
   Last Name  <input name="lasttname" value="[% record.lastname %]">
   <input type="submit">
  </form>

Usually there is no need to specify the C<action> of the
form : the default action sent by the browser
will be the same URL (including the query parameter
C<?A> or C<?M=[% record.Id %]>), and when the application
receives a POST request, it knows it has 
to update or add the record instead of displaying the form.
This implies that you B<must> use the POST method for any data
modification; whereas forms for searching may use either GET or POST methods.

For convenience, deletion through a GET url of shape
C<?D=[% record.Id %]> is supported; however, 
data modification through GET method is not recommended,
and therefore it is preferable to write

  <form method="post">
    <input name="D" value="[% record.Id %]">
    <input type="submit" value="Delete this record">
  </form>

=head3 Searching

A typical form for searching will look like

  <form method="POST" action="[% self.url %]">
     Search : 
       <select name="S">
         <option value="">--Choose in field1--</option>
         <option value="+field1:val1">val1</option>
         <option value="+field1:val2">val2</option>
         ...
       </select>
       Other : <input name="S">
   <input type="submit">
  </form>

So the form can combine several search criteria, all passed through the
C<S> parameter. The form method can be either GET or POST; but if 
you choose POST, then it is recommended that you also specify

   action="[% self.url %]"

instead of relying on the implicit self-url from the browser. 
Otherwise the URL displayed in the browser may still contain
some all criteria from a previous search, while the current
form sends other search criteria --- the application will 
not get confused, but the user might.

=head2 Highlighting the searched words

The C<preMatch> and C<postMatch> parameters 
in the configuration file (see below) define some
marker strings that will be automatically inserted 
in the data returned by a search, surrounding each word
that was mentioned in the query. These marker strings 
should be chosen so that they would unlikely mix with 
regular data or with HTML markup : the recommanded
values are 

  preMatch  {[
  postMatch ]}

Then you can exploit that marking within your templates
by calling the L</highlight> and L</unhighlight> 
template filters, described below.


=head1 CONFIGURATION FILE

The configuration file is always stored within the C<htdocs>
directory, at the location corresponding to the application
URL : so for application F<http://myServer/some/data.ftw>,
the configuration file is in 

    /path/to/http/htdocs/some/data.ftw

Because of the Apache configuration directives described above,
the URL is always served by C<File::Tabular::Web>, so there
is no risk of users seing the content of the configuration
file.

The configuration is written in L<Appconfig|Appconfig> format.
This format supports comments (starting with C<#>), 
continuation lines (through final C<\>), "heredoc" quoting
style for multiline values, and section headers similar
to a Windows INI file. All details about the configuration
file format can be found in L<Appconfig::File>.

Below is the list of the various recognized sections and parameters.

=head2 Global section

The global section (without any section header) can contain
general-purpose parameters that can be retrieved later from 
the viewing templates through C<< [% self.cfg.<param> %] >>;
this is useful for example for setting a title or other
values that will be common to all templates.

The global section may also contain some
options to L<File::Tabular/new> :
C<preMatch>, C<postMatch>, C<avoidMatchKey>, C<fieldSep>, C<recordSep>.

Option C<highlightClass> defines the class name
used by the L</highlight> filter (default is C<HL>).


=head2 [fixed] / [default]

The C<fixed> and C<default> sections 
simulate parameters to the request.
Specifications in the C<fixed> section are stronger
than HTTP parameters; specifications in the 
C<default> section are weaker : the L<param|param>
method for the application will first look in the C<fixed> section, 
then in the HTTP request, and finally in the C<default> section.
So for example with 

  [fixed]
  count=50
  [default]
  orderBy=lastname

a request like

  ?S=*&count=20

will be treated as

  ?S=*&count=50&orderBy=lastname


Relevant parameters to put in C<fixed> or in C<default>
are described in section L</S> of this documentation :
for example C<count>, C<orderBy>, etc.


=head2 [application]

=over

=item C<< dir=/some/directory >>

Directory where application files reside.
By default : same directory as the configuration file.

=item C<< name=some_name >>

Name of the application (will be used for example
as prefix to find template files).
Single-level name, no pathnames allowed.

=item C<< data=some_name >>

Name of the tabular file containing the data.
Single-level name, must be in the application directory.
By default: application name with the C<.txt> suffix appended.

=item C<< class=My::File::Tabular::Web::Subclass >>

Will dynamically load the specified module and use it as 
class for objects of this application. The specified module
must be a subclass of C<File::Tabular::Web>.

=item C<< useFileCache=1 >>

If true, the whole datafile will be slurped into memory and reused
across requests (except update requests).

=item C<< mtime=<format> >>

Format to display the last modified time of the data file,
using  L<POSIX strftime()|POSIX/strftime>.
The result will be available to templates in C<< [% self.mtime %] >>

=back



=head2 [permissions]

This  section specifies permissions to perform operations
within the application. Of course we need
Apache to be configured to do some kind of authentification,
so that the application receives a user name 
through the C<REMOTE_USER> environment variable;
many authentification modules are available, 
see C<Apache/manual/howto/auth.html>.
Otherwise the default user name received
by the application is "Anonymous".

Apache may also be configured to do some kind of authorisation checking,
but this will control access to the application as a whole, whereas
here we configure fine-grained permissions for various operations.

Builtin permission names are : 
C<search>,
C<read>,
C<add>,
C<delete>,
C<modif>,
and C<download>.
Each name also has a I<negative> counterpart, i.e.
C<no_search>,
C<no_read>, etc.

For each of those permission names, the configuration can
give a list of user names
separated by commas or spaces : the current user name will be 
compared to this list. A permission may also specify 'C<*>', which
means 'everybody' : this is the default for
permissions C<read>, C<search> and C<download>.
There is no builtin notion of "user groups", but 
you can introduce such a notion by writing a subclass which overrides the
L</user_match> method.

Permissions may also be granted or denied
on a per-record basis : writing C<< $fieldname >> (starting
with a literal dollar sign) means that 
users can access records in which the content of  C<< fieldname >>
matches their username. Usually this is associated 
with an I<automatic user field> (see below), so that
the user who created a new record can later modify it.

Example :

  [permissions]
   read   = * # the default, could have been omitted
   search = * # idem
   add    = andy bill 
   modif  = $last_author # username must match content of field 'last_author'
   delete = $last_author



=head2 [fields]

The C<fields> section specifies some specific
information about fields in the tabular file.

=over

=item C<< time <field> = <format>  >>

Declares C<< field >> to be a I<time field>, which means that whenever
a record is updated, the current local time will be automatically
inserted in that field. The I<format> argument will be
passed to L<POSIX strftime()|POSIX/strftime>. Ex :

  time DateModif = %d.%m.%Y    
  time TimeModif = %H:%M:%S

=item C<< user = <field>  >>

Declares C<< field >> to be a I<user field>, which means that whenever
a record is updated, the current username will be automatically
inserted in that field.

=item C<< default <field> = <value> >>

Default values for some fields ; will be inserted into new records.

=item C<< autoNum <field>  >>

Activates autonumbering for new records ; the number will be
stored in the given field. Automatically implies that
C<< default <field> = '#' >>.


=back


Subclasses may add more entries in this section
(for example for specifying fields that will hold names
of attached documents).



=head2 [template]

This section specifies where to find templates for various views.
The specified locations will be looked for in several directories:
the application template directory (as specified by C<dir> directive, 
see below), 
the application directory,
the default C<File::Tabular::Web> template directory
(as specified by the C<app_tmpl_default_dir> method), 
or the subdirectory C<default> of the above.

=over

=item dir

specifies the application template directory

=item short

Template for the "short" display of records (typically 
a table for presenting search results). 

=item long

Template for the "long" display of records (typically 
for a detailed presentation of a single record ). 

=item modif

Template for editing a record (typically this will be a form
with an action to call the update URL (C<?M=key>).

=item msg

Template for presenting special messages to the user 
(messages after a record update or deletion, or error messages).

=item home

Homepage for the application.

=back


Defaults for these templates are
C<< <application_name>_short.tt >>, 
C<< <application_name>_long.tt >>, etc.


=head1 METHODS

The only I<public> method is the L</handler> method,
to be called from mod_perl or from a cgi-bin script.

All other methods are internal to the application,
i.e. not meant to be called from external code.
They are documented here in case you would want 
to subclass the package. If you don't need
subclassing, you can B<ignore this whole section>.

Methods starting with an underscore are meant to
be I<private>, i.e. should not be redefined in subclasses.
All other methods are I<protected>.

Currently we use plain old Perl inheritance
and calls to C<SUPER>. A future move 
to the C3 method resolution order (see L<Class::C3>) is planned,
but is not totally trivial because classes are sometimes
loaded dynamically.


=head2 Entry point

=head3 handler

  File::Tabular::Web->handler;

This is the main entry point into the module. It creates a new request
object, initializes it from information passed through the URL and
through CGI parameters, processes the request, and generates
the answer. In case of error, the page contains an error message.


=head2 Methods for creating / initializing "application" hashrefs

=head3 _app_new

Reads the configuration file for a given application
and creates a hashref storing the information.
The hashref is put in a global cache of all applications
loaded so far.

This method should not be overridden in subclasses;
if you need specific code to be executed, use
the L</app_initialize> method.

=head3 _app_read_config

Glueing code to the L<AppConfig> module.

=head3 app_initializea

Initializes the application hashref. In particular,
it creates the L<Template> object, with appropriate
settings to specify where to look for templates.

If you override this method in subclasses, 
you should probably call C<SUPER::app_initialize>.

=head3 app_tmpl_default_dir

Returns the default directory containing templates.
The default is C<< <server_root>/lib/tmpl/ftw >>.

=head3 app_tmpl_filters

Returns a hashref of filters to be passed to 
the Template object (see L<Template::Filters>).

The default contains two filters, which work together
with the C<preMatch> and C<postMatch> parameters of the
configuration file. Suppose the following configuration :

  preMatch  {[
  postMatch ]}

Then the filters are defined as follows :

=over

=item highlight

Replaces strings of shape C<< {[...[} >> by 
C<< <span class="HL">...</span> >>.

The class name is C<HL> by default, but another name can be
defined through the C<highlightClass> configuration parameter.
Templates have to define a style for that class, like for 
example 

  <style>
    .HL {background: lightblue}
  </style>


=item unhighlight

Replaces strings of shape C<< {[...[} >> by 
C<< ... >> (i.e. removes the marking).

=back

These filters are intended to help 
highlighting the words matched by a search request ; 
usually this must happen I<after> the data has been
filtered for HTML entities. So a typical use
in a template would be for example 

  <a href="/some/url?with=[% record.foo | unhighlight | uri %]">
      link to [% record.foo | html | highlight %]
  </a>



=head3 app_phases_definition

As explained above in section L</"WEB API">, various
entry points into the application are chosen by single-letter
arguments; here this method returns a table that specifies what happens
for each of them. 

A letter in the table is associated to a hashref,
with the following keys :

=over

=item pre

name of method to be executed in the "data preparation phase"

=item op

name of method to be executed in the "data manipulation phase"

=item view

name of view for displaying the results

=back


=head2 Methods for instance creation / initialization


=head3 _new

Creates a new object, which represents an HTTP request
to the application. The class for the created object is 
generally C<File::Tabular::Web>, unless specified otherwise
in the the configuration file (see the C<class> entry
in section L</"CONFIGURATION FILE">).

The C<_new> method cannot be redefined in subclasses; if you need
custom code to be executed, use L</initialize> or L</app_initialize>
(both are invoked from C<_new>).

=head3 initialize

Code to initialize the object. The default behaviour is
to setup C<max>, C<count> and C<orderBy> within the 
object hash.


=head3 _setup_phases

Reads the phases definition table and decides about what to 
do in the next phases.

=head3 open_data

Retrieves the name of the datafile, decides whether it
should be opened for readonly or for update, and 
creates a corresponding L<File::Tabular|File::Tabular> object. 
The datafile may be cached in memory if directive C<useFileCache> is
activated.

=head3 _cached_content

Implementation of the memory cache;
checks the modification time of the file
to detect changes and invalidate the cache.


=head2 Methods that can be called from templates

=head3 param

  [% self.param %]

With no argument, returns the list of parameter names 
to the current HTTP request. 

  [% self.param(param_name) %]

With an argument, 
returns the value that was specified under C<$param_name> in the
HTTP request, or in the configuration file (see the 
description of C<< [fixed]/[default] >> sections).
The return value is always a scalar
(so this is I<not exactly the same> as calling 
C<< cgi.param(...) >>). If the HTTP request contains
multiple values under the same name, these values
are joined with a space. Initial
and trailing spaces are automatically removed.

If you need to access the list of values in the HTTP request,
you can always call 

  [% self.cgi.param(param_name) %]

or 

  [% self.APR_request.param(param_name) %]

(whichever is appropriate).


=head3 can_do

  [% self.can_do($action, [$record]) %]

Tells whether the current user has permission to do 
C<$action> (which might be 'modif', 'delete', etc.).
See explanations above about how permissions are specified
in the initialization file.
Sometimes permissions are setup in a record-specific way
(for example one data field may contain the names of 
authorized users); the second optional argument 
is meant for those cases, so that C<can_do()> can inspect the current
data record.

=head2 Request handling : general methods

=head3 _dispatch_request

Executes the various phases of request handling

=head3 display

Finds the template corresponding to the view name,
gathers its output, and prints it together with 
some HTTP headers.

=head3 _emit_page

Internal method for printing headers and body, 
using API from modperl or CGI.

=head2 Request handling : search methods

=head3 search_key

Search a record with a specific key.
Puts the result into C<< $self->{result} >>.

=head3 search

Search records matching given criteria
(see L<File::Tabular|File::Tabular> for details).
Puts results into C<< $self->{result} >>.

=head3 before_search

Initializes C<< $self->{search_string} >>.
Overridden in subclasses for more specific
searching (like for example adding fulltext search
into attached documents).

=head3 sort_and_slice

Choose a slice within the result set, according
to pagination parameters C<count> and C<start>.

=head3 _url_for_next_slice

Returns an URL to the next or previous slice,
using L</"params_for_next_slice">.

=head3 params_for_next_slice

Returns an array of strings C<"param=value"> that will
be inserted into the URL for next or previous slice.

=head3 words_queried

List of words found in the query string
(to be used for example for highlighting those words
in the display).

=head2 Update Methods

=head3 empty_record

Generates an empty record (preparation for adding
a new record). Fields are filled with default values
specified in the configuration file.


=head3 update

Checks for permission and then performs the update.
Most probably you don't want to override this
method, but rather the methods C<before_update> or C<after_update>.

=head3 before_update

Copies values from HTTP parameters into the record,
and automatically fills the user name or current time/date
in appropriate fields.

=head3 after_update

Hook for any code to perform after an update (useful
for example for attached documents).

=head3 rollback_update

Hook for any code to roll back whatever was performed
in C<before_update>, in case the update failed (useful
for example for attached documents).

=head2 Delete Methods

=head3 delete

Checks for permission and then performs the delete.
Most probably you don't want to override this
method, but rather the methods C<before_delete> or C<after_delete>.

=head3 before_delete

Hook for any code to perform before a delete.

=head3 after_delete

Hook for any code to perform aftere a delete.

=head2 Miscellaneous methods

=head3 prepare_download

Checks for permission to download the whole dataset.

=head3 print_help

Prints help. Not implemented yet.

=head3 user_match

  $self->user_match($access_control_list)

Returns true if the current user (as stored
in C<<  $self->{user} >> "matches" the access 
control list (given as an argument string).

The meaning of "matches" may be redefined in subclasses;
the default implementation just performs a regex 
case-insensitive search within the list for a complete 
word equal to the username.

Override in subclasses if you need other authorization
schemes (like for example dealing with groups).

=head3 key_field

Returns the name of the key field in the data file.

=head3 key

  my $key = $self->key($record);

Returns the value in the first field of the record.


=head1 AUTHOR

Laurent Dami, C<< <laurent.d...@justice.ge.ch> >>

=head1 COPYRIGHT & LICENSE

Copyright 2007 Laurent Dami, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.



=begin comment

TODO 

 - check completeness of logging code
 - simplify app_init for Template->new
 - how to remove an attached document
 - system to control headers
 - automatically set expire header if modify is enabled
 - create logger in new() + use Time::HiRes
 - server-side record validation using "F::T where syntax" (f1 > val, etc.)
    or using code hook
 - more clever generation of wordsQueried in search
 - options qw/preMatch postMatch avoidMatchKey fieldSep recordSep/
    should be in a specific section
 - make compatibility with modperl1
 - dynamic menus presenting all possible values (like Excel automatic filter)


TO CHECK WHEN UPGRADING

  - permissions, esp. permission to add/modif (see Jetons PH)
 - 'add' permission without 'modif' 
  - remove calls to [% self.url('foobar') %]
  - config : autoNum and not autonum

=end comment







