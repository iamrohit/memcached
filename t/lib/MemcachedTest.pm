package MemcachedTest;
use strict;
use IO::Socket::INET;
use IO::Socket::UNIX;
use Exporter 'import';
use Carp qw(croak);
use vars qw(@EXPORT);

# Instead of doing the substitution with Autoconf, we assume that
# cwd == builddir.
use Cwd;
my $builddir = getcwd;


@EXPORT = qw(new_memcached sleep mem_get_is mem_gets mem_gets_is mem_stats);

sub sleep {
    my $n = shift;
    select undef, undef, undef, $n;
}

sub mem_stats {
    my ($sock, $type) = @_;
    $type = $type ? " $type" : "";
    print $sock "stats$type\r\n";
    my $stats = {};
    while (<$sock>) {
        last if /^(\.|END)/;
        /^(STAT|ITEM) (\S+)\s+([^\r\n]+)/;
        #print " slabs: $_";
        $stats->{$2} = $3;
    }
    return $stats;
}

sub mem_get_is {
    # works on single-line values only.  no newlines in value.
    my ($sock_opts, $key, $val, $msg) = @_;
    my $opts = ref $sock_opts eq "HASH" ? $sock_opts : {};
    my $sock = ref $sock_opts eq "HASH" ? $opts->{sock} : $sock_opts;

    my $expect_flags = $opts->{flags} || 0;
    my $dval = defined $val ? "'$val'" : "<undef>";
    $msg ||= "$key == $dval";

    print $sock "get $key\r\n";
    if (! defined $val) {
        my $line = scalar <$sock>;
        if ($line =~ /^VALUE/) {
            $line .= scalar(<$sock>) . scalar(<$sock>);
        }
        Test::More::is($line, "END\r\n", $msg);
    } else {
        my $len = length($val);
        my $body = scalar(<$sock>);
        my $expected = "VALUE $key $expect_flags $len\r\n$val\r\nEND\r\n";
        if (!$body || $body =~ /^END/) {
            Test::More::is($body, $expected, $msg);
            return;
        }
        $body .= scalar(<$sock>) . scalar(<$sock>);
        Test::More::is($body, $expected, $msg);
    }
}

sub mem_gets {
  # works on single-line values only.  no newlines in value.
  my ($sock_opts, $key) = @_;
  my $opts = ref $sock_opts eq "HASH" ? $sock_opts : {};
  my $sock = ref $sock_opts eq "HASH" ? $opts->{sock} : $sock_opts;
  my $val;
  my $expect_flags = $opts->{flags} || 0;

  print $sock "gets $key\r\n";
  my $response = <$sock>;
  if ($response =~ /^END/) {
    return "NOT_FOUND";
  }
  else
  {
    $response =~ /VALUE (.*) (\d+) (\d+) (\d+)/;
    my $flags = $2;
    my $len = $3;
    my $identifier = $4;
    read $sock, $val , $len;
    # get the END
    $_ = <$sock>;
    $_ = <$sock>;

    return ($identifier,$val);
  }

}
sub mem_gets_is {
    # works on single-line values only.  no newlines in value.
    my ($sock_opts, $identifier, $key, $val, $msg) = @_;
    my $opts = ref $sock_opts eq "HASH" ? $sock_opts : {};
    my $sock = ref $sock_opts eq "HASH" ? $opts->{sock} : $sock_opts;

    my $expect_flags = $opts->{flags} || 0;
    my $dval = defined $val ? "'$val'" : "<undef>";
    $msg ||= "$key == $dval";

    print $sock "gets $key\r\n";
    if (! defined $val) {
        my $line = scalar <$sock>;
        if ($line =~ /^VALUE/) {
            $line .= scalar(<$sock>) . scalar(<$sock>);
        }
        Test::More::is($line, "END\r\n", $msg);
    } else {
        my $len = length($val);
        my $body = scalar(<$sock>);
        my $expected = "VALUE $key $expect_flags $len $identifier\r\n$val\r\nEND\r\n";
        if (!$body || $body =~ /^END/) {
            Test::More::is($body, $expected, $msg);
            return;
        }
        $body .= scalar(<$sock>) . scalar(<$sock>);
        Test::More::is($body, $expected, $msg);
    }
}

sub supports_udp {
    return 1;
}

sub reaper {
    wait;
    $SIG{CHLD} = \&reaper;
}
$SIG{CHLD} = \&reaper;

sub new_memcached {
    my ($args, $passed_port) = @_;
    my $port = $passed_port || -1;
    my $udpport = -1;
    $args .= " -p $port";
    if (supports_udp()) {
        $args .= " -U $udpport";
    }
    if ($< == 0) {
        $args .= " -u root";
    }

    my $random = rand();
    my $portfile = "/tmp/ports.$$.$random";
    my $env_vars = "MEMCACHED_PORT_FILENAME=$portfile";

    my $exe = "$builddir/memcached-debug";
    croak("memcached binary doesn't exist.  Haven't run 'make' ?\n") unless -e $exe;
    croak("memcached binary not executable\n") unless -x _;

    my $childpid = fork();
    unless ($childpid) {
        my $cmd = "/usr/bin/env $env_vars $builddir/timedrun 600 $exe $args";
        exec $cmd;
        exit; # never gets here.
    }

    unless ($args =~ /-s (\S+)/) {
        my $tries = 100;
        while (($args =~ /-d/ || kill(0, $childpid) == 1) && ! -e $portfile) {
            select undef, undef, undef, 0.10;
            if (--$tries == 0) {
                die("Couldn't ever get the port file.");
            }
        }

        open(my $pf, "< $portfile") || die("Could not open $portfile");
        while(<$pf>) {
            if (/^TCP INET: (\d+)/) {
                $port = $1;
            } elsif (/^UDP INET: (\d+)/) {
                $udpport = $1;
            }
        }
        close($pf);
        print "Detected ports:  $port/$udpport\n";
    }
    unlink($portfile);

    # unix domain sockets
    if ($args =~ /-s (\S+)/) {
        sleep 1;
	my $filename = $1;
	my $conn = IO::Socket::UNIX->new(Peer => $filename) || 
	    croak("Failed to connect to unix domain socket: $! '$filename'");

	return Memcached::Handle->new(pid  => $childpid,
				      conn => $conn,
				      domainsocket => $filename,
				      port => $port);
    }

    # try to connect / find open port, only if we're not using unix domain
    # sockets

    for (1..20) {
	my $conn = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port");
	if ($conn) {
	    return Memcached::Handle->new(pid  => $childpid,
					  conn => $conn,
					  udpport => $udpport,
					  port => $port);
	}
	select undef, undef, undef, 0.10;
    }
    croak("Failed to startup/connect to memcached server.");
}

############################################################################
package Memcached::Handle;
sub new {
    my ($class, %params) = @_;
    return bless \%params, $class;
}

sub DESTROY {
    my $self = shift;
    kill 2, $self->{pid};
}

sub port { $_[0]{port} }
sub udpport { $_[0]{udpport} }

sub sock {
    my $self = shift;

    if ($self->{conn} && ($self->{domainsocket} || getpeername($self->{conn}))) {
	return $self->{conn};
    }
    return $self->new_sock;
}

sub new_sock {
    my $self = shift;
    if ($self->{domainsocket}) {
	return IO::Socket::UNIX->new(Peer => $self->{domainsocket});
    } else {
	return IO::Socket::INET->new(PeerAddr => "127.0.0.1:$self->{port}");
    }
}

sub new_udp_sock {
    my $self = shift;
    return IO::Socket::INET->new(PeerAddr => '127.0.0.1',
                                 PeerPort => $self->{udpport},
                                 Proto    => 'udp',
                                 LocalAddr => '127.0.0.1',
                                 );
}

1;
