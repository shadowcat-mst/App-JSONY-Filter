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
  my sub each_line_of ($buffref, $cb) {
    while($$buffref =~ s/^(.*)\r?\n//) {
      $cb->($1);
    }
  }
  my $write_stdio = $stdio->curry::weak::write;
  my $write_proc = $proc->fd(0)->curry::weak::write;
  $stdio->configure(
    on_read => sub ($stream, $buffref, $eof) {
      each_line_of $buffref, sub ($line) {
        $write_proc->(encode_json(JSONY->load($line)));
      }
    }
  );
  $proc->fd(1)->configure(
    on_read => sub ($stream, $buffref, $eof) {
      each_line_of $buffref, sub ($line) {
        $write_stdio->(jdc(decode_json($line)));
      }
    }
  );
};

1;
