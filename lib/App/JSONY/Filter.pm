package App::JSONY::Filter;

use Moo;
use CLI::Osprey;

use warnings FATAL => 'uninitialized';
use experimental 'signatures';

use curry;
use JSONY;
use JSON::Dumper::Compact qw(jdc);
use JSON::MaybeXS;

use aliased 'IO::Async::Loop';
use aliased 'IO::Async::Process';
use aliased 'IO::Async::Stream';

has loop => (is => 'lazy', builder => sub { Loop->new });

BEGIN {
  package App::JSONY::Filter::_RunSyntax;

  use Keyword::Simple;

  sub import {
    Keyword::Simple::define foreach_line_of => sub ($ref) {
      die "Invalid syntax for foreach_line_of"
        unless $$ref =~ s/^\s*(\S+)\s+{/_foreach_line_of $1, sub {/;
    };
    Keyword::Simple::define writer_for => sub ($ref) {
      die "Invalid syntax for writer_for"
        unless $$ref =~
          s{^\s*(\w+)\s+(\S+);}
           {my sub write_to_$1 (\$data) { $2->write(\$data."\\n"); return }};
    }
  }
  $INC{join('/', split '::', __PACKAGE__).'.pm'} = __FILE__;
}


subcommand run => sub ($self, $parent, @args) {

  use App::JSONY::Filter::_RunSyntax;
  use Feature::Compat::Try;
  use Feature::Compat::Defer;
  use Future::AsyncAwait;

  my sub decode_jsony ($data) { JSONY->load($data) }

  my $loop = $parent->loop;

  my sub with_timeout ($time, $thing_f) {
    my $timeout_f = $loop->timeout_future(after => $time);
    Future->wait_any($timeout_f, $thing_f);
  }

  my sub on_event_start ($thing, $event, $start) {
    $thing->configure($event => sub ($self) {
      $self->adopt_future($start->());
      return;
    });
    return;
  }
  
  my sub on_signal_start ($name, $start) {
    my $signal = IO::Async::Signal->new(name => $name);
    on_event_start $signal, on_receipt => $start;
    $loop->add($signal);
    return;
  }

  my sub _foreach_line_of ($stream, $cb) {
    my $reader = $stream->curry::weak::read_until("\n");
    my sub read_next_line () { $reader->() }
    my $closer = $stream->curry::weak::close_now;
    my sub close_stream () { $closer->() }

    $stream->adopt_future((async sub {
      my ($line, $eof);
      while (!$eof) {
        ($line, $eof) = await read_next_line;
        next unless $line =~ /\n$/;
        local $_ = $line;
        $cb->($line);
      }
      close_stream;
      return;
    })->());

    return;
  }

  my sub shutdown_cb_for ($proc) {
    my $finished_f = $proc->finished_future;
    my $am_running = 0;
    my $closer = $proc->fd(0)->curry::weak::close_now;
    my sub close_stdin () { $closer->() }
    my $killer = $proc->curry::weak::kill;
    my sub kill_proc ($sig) { defined($sig) and $killer->($sig) }

    return async sub {

      return if $am_running; # one at a time, please

      $am_running = 1;

      defer { $am_running = 0 }

      close_stdin;

      SIG: foreach my $sig (undef, qw(INT TERM TERM KILL)) {
        kill_proc $sig;
        try {
          await with_timeout 3, $finished_f;
          return;
        } catch ($e) {
          next SIG; 
        }
      }
      warn "Child process ignored SIGKILL after 3 seconds, giving up\n";
      return;
    }
  };

  die "No command given" unless @args;

  my $stdio = Stream->new_for_stdio;
  my $proc = Process->new(command => \@args);

  writer_for stdio $stdio;
  writer_for proc $proc->fd(1);

  foreach_line_of $stdio { write_to_proc encode_json decode_jsony $_ };

  foreach_line_of $proc->fd(0) { write_to_stdio jdc decode_json $_ };

  for my $shutdown (shutdown_cb_for $proc) {

    on_event_start $stdio, on_closed => $shutdown;

    on_signal_start INT => $shutdown;
  }

  $loop->add($_) for ($stdio, $proc);

  $loop->await($proc->finished_future);

  return;
};

1;
