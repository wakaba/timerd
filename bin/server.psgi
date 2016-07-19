# -*- perl -*-
use strict;
use warnings;
use Path::Tiny;
use Promise;
use Dongry::Database;
use Dongry::Type;
use Wanage::HTTP;
use Warabe::App;
use Web::URL;
use Web::Transport::ConnectionClient;

$ENV{LANG} = 'C';
$ENV{TZ} = 'UTC';
$Wanage::HTTP::UseXForwardedScheme = 1 if $ENV{APP_WITH_RPROXY};
my $APIKey = $ENV{APP_API_KEY};
die "Bad |APP_API_KEY|" unless defined $APIKey;

sub run_task ($) {
  my $db = $_[0];
  return $db->execute ('select * from task where `at` < ? order by `at` asc limit 1', {
    at => time,
  }, source_name => 'master')->then (sub {
    my $task = $_[0]->first;
    return 0 unless defined $task;
    return $db->delete ('task', {
      at => $task->{at},
      url => $task->{url},
      method => $task->{method},
    })->then (sub {
      return '0 but true' unless $_[0]->row_count >= 1;
      my $url = Web::URL->parse_string (Dongry::Type->parse ('text', $task->{url}));
      my $con = Web::Transport::ConnectionClient->new_from_url ($url);
      return $con->request (url => $url, method => $task->{method})->then (sub {
        return $con->close;
      })->then (sub {
        return 1;
      }, sub {
        warn $_[0];
        return 1;
      });
    });
  });
} # run_task

sub main ($$) {
  my ($app, $db) = @_;
  my $path = $app->path_segments;
  $app->http->set_response_header ('Cache-Control', 'no-store');

  my $key = $app->bare_param ('key') || '';
  $app->throw_error (403, reason_phrase => 'Bad |key|')
      unless $key eq $APIKey;

  if (@$path == 1 and $path->[0] eq '') {
    # /
    if ($app->http->request_method eq 'POST') {
      my $at = $app->bare_param ('at');
      return $app->throw_error (400, reason_phrase => 'Bad |at|')
          unless defined $at;
      my $url = $app->text_param ('url') || '';
      $url = Web::URL->parse_string ($url);
      return $app->throw_error (400, reason_phrase => 'Bad |url|')
          unless defined $url and ($url->scheme eq 'https' or $url->scheme eq 'http');
      my $method = $app->bare_param ('method');
      $method = 'GET' unless defined $method;
      return $db->execute (q{
create table if not exists `task` (
  `at` double not null,
  `url` varbinary(1023) not null,
  `method` varbinary(15) not null,
  key (`at`),
  key (`url`)
) default charset=binary engine=innodb
      })->then (sub {
        return $db->insert ('task', [{
          at => 0+$at,
          url => Dongry::Type->serialize ('text', $url->stringify),
          method => Dongry::Type->serialize ('text', $method),
        }], duplicate => 'replace');
      })->then (sub {
        return $app->throw_error (204, reason_phrase => 'Scheduled');
      });
    }
  }

  if (@$path == 1 and $path->[0] eq 'heartbeat') {
    # /heartbeat

    my $try; $try = sub {
      return run_task ($db)->then (sub {
        return $try->() if $_[0];
      });
    }; # $try
    return $try->()->then (sub {
      undef $try;
      return $app->throw_error (204);
    }, sub {
      undef $try;
      die $_[0];
    });
  }

  return $app->throw_error (404);
} # main

{
  my $dsn;
  my $cleardb = $ENV{CLEARDB_DATABASE_URL} || '';
  if ($cleardb =~ m{^mysql://([^:]+):([^\@]+)\@([^/]+)/([^?]+)\?}) {
    $dsn = "dbi:mysql:dbname=$4;host=$3;user=$1;password=$2";
  }
  die "No |CLEARDB_DATABASE_URL|" unless defined $dsn;
  my $cert_file_name = $ENV{CLEARDB_CERT_FILE};
  die "No |CLEARDB_CERT_FILE|" unless defined $cert_file_name;
  $dsn .= ";mysql_ssl_ca_file=$cert_file_name";
  my $DBSource = {dsn => $dsn, writable => 1, anyevent => 1};

  return sub {
    ## This is necessary so that different forked siblings have
    ## different seeds.
    srand;

    ## XXX Parallel::Prefork (?)
    delete $SIG{CHLD};
    delete $SIG{CLD};

    my $http = Wanage::HTTP->new_from_psgi_env ($_[0]);
    my $app = Warabe::App->new_from_http ($http);

    warn sprintf "Access: [%s] %s %s\n",
        scalar gmtime, $app->http->request_method, $app->http->url->stringify;

    my $db = Dongry::Database->new (sources => {master => $DBSource});

    return $app->execute_by_promise (sub {
      return Promise->resolve->then (sub {
        return main ($app, $db);
      })->then (sub {
        return $db->disconnect;
      }, sub {
        my $e = $_[0];
        #http_post
        #    url => $Config->{ikachan_prefix} . '/privmsg',
        #    params => {
        #      channel => $Config->{ikachan_channel},
        #      message => (sprintf "%s %s", __PACKAGE__, $_[0]),
        #      #rules => $rules,
        #    },
        #    anyevent => 1;
        return $db->disconnect->then (sub { die $e }, sub { die $e });
      });
    });
  };
}

=head1 LICENSE

Copyright 2016 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <http://www.gnu.org/licenses/>.

=cut
