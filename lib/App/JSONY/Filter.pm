package App::JSONY::Filter;

use strict;
use warnings;
use warnings FATAL => 'uninitialized';
use experimental 'signatures';

use curry;
use JSONY;
use JSON::Dumper::Compact qw(jdc);
use JSON::MaybeXS;

use aliased 'IO::Async::Loop';
use aliased 'IO::Async::Process';
use aliased 'IO::Async::Stream';

use CLI::Osprey;

has loop => (is => 'lazy', sub { Loop->new });

subcommand run => sub ($self, @args) {
  my $loop = $self->loop;
  my $stdio = Stream->new_for_stdio;
  my $proc = Process->new(command => \@args);
  my sub foreach_line_read :prototype(&) ($cb) {
    sub ($buffref, @) {
      while($$buffref =~ s/^(.*)\r?\n//) {
        local $_ = $1;
        $cb->($1);
      }
    }
  }
  my $write_to_stdio = $stdio->curry::weak::write;
  my $write_to_proc = $proc->fd(1)->curry::weak::write;
  $stdio->configure(
    on_read => foreach_line_read {
      $write_to_proc->(encode_json(JSONY->load($_)));
    },
    on_close => $loop->curry::stop,
  );
  $proc->fd(0)->configure(
    on_read => foreach_line_read {
      $write_to_stdio->(jdc(decode_json($_)));
    },
    on_close => $loop->curry::stop,
  );
  $loop->add($_) for ($stdio, $proc);
  $loop->start;
};

1;
