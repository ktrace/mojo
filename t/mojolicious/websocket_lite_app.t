use Mojo::Base -strict;

BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Test::Mojo;
use Test::More;
use Mojo::ByteStream qw(b);
use Mojo::JSON       qw(encode_json);
use Mojolicious::Lite;

websocket '/echo' => sub {
  my $c = shift;
  $c->tx->max_websocket_size(65538)->with_compression;
  $c->on(binary => sub { shift->send({binary => shift}) });
  $c->on(
    text => sub {
      my ($c, $bytes) = @_;
      $c->send("echo: $bytes");
    }
  );
} => 'echo';

get '/echo' => {text => 'plain echo!'};

any '/not_echo/<code:num>' => sub {
  my $c = shift;
  $c->res->code($c->param('code'));
  $c->redirect_to('echo');
};

websocket '/no_compression' => sub {
  my $c = shift;
  $c->on(binary => sub { shift->send({binary => shift}) });
  $c->render(text => 'this should be ignored', status => 101);
};

websocket '/protocols' => sub {
  my $c = shift;
  $c->send($c->tx->with_protocols('foo', 'bar', 'baz', '0') // 'none');
  $c->send($c->tx->protocol // 'none');
};

websocket '/json' => sub {
  my $c = shift;
  $c->on(
    json => sub {
      my ($c, $json) = @_;
      return $c->send({json => $json}) unless ref $json;
      return $c->send({json => [@$json, 4]}) if ref $json eq 'ARRAY';
      $json->{test} += 1;
      $c->send({json => $json});
    }
  );
};

websocket '/timeout' => sub {
  my $c = shift;
  $c->on(
    message => sub {
      my ($c, $msg) = @_;
      $c->inactivity_timeout($msg) unless $msg eq 'timeout';
      $c->send("$msg: " . Mojo::IOLoop->stream($c->tx->connection)->timeout);
    }
  );
};

get '/plain' => {text => 'Nothing to see here!'};

websocket '/push' => sub {
  my $c  = shift;
  my $id = Mojo::IOLoop->recurring(0.1 => sub { $c->send('push') });
  $c->on(finish => sub { Mojo::IOLoop->remove($id) });
};

websocket '/unicode' => sub {
  my $c = shift;
  $c->on(
    message => sub {
      my ($c, $msg) = @_;
      $c->send("♥: $msg");
    }
  );
};

websocket '/bytes' => sub {
  my $c = shift;
  $c->on(
    frame => sub {
      my ($ws, $frame) = @_;
      $ws->send({$frame->[4] == 2 ? 'binary' : 'text', $frame->[5]});
    }
  );
};

websocket '/once' => sub {
  my $c = shift;
  $c->on(
    message => sub {
      my ($c, $msg) = @_;
      $c->send("ONE: $msg");
    }
  );
  $c->tx->once(
    message => sub {
      my ($tx, $msg) = @_;
      $c->send("TWO: $msg");
    }
  );
};

websocket '/close' => sub { shift->finish(1001) };

websocket '/one_sided' => sub {
  shift->send('I ♥ Mojolicious!' => sub { shift->finish });
};

under '/nested';

websocket sub {
  my $c    = shift;
  my $echo = $c->cookie('echo') // '';
  $c->cookie(echo => 'again');
  $c->on(
    message => sub {
      my ($c, $msg) = @_;
      $c->send("nested echo: $msg$echo")->finish(1000);
    }
  );
};

get {text => 'plain nested!'};

post {data => 'plain nested too!'};

my $t = Test::Mojo->new;

subtest 'Simple roundtrip' => sub {
  $t->websocket_ok('/echo')->send_ok('hello')->message_ok->message_is('echo: hello')->finish_ok;
};

subtest 'Multiple roundtrips' => sub {
  $t->websocket_ok('/echo')->send_ok('hello again')->message_ok->message_is('echo: hello again')
    ->send_ok('and one more time')
    ->message_ok->message_is('echo: and one more time')->finish_ok;
};

subtest 'Simple roundtrip with redirect' => sub {
  $t->get_ok('/not_echo/308')->status_is(308);
  $t->ua->max_redirects(10);
  $t->get_ok('/not_echo/302')->status_is(200)->content_is('plain echo!');
  $t->websocket_ok('/not_echo/308')->send_ok('hello')->message_ok->message_is('echo: hello')->finish_ok;
  $t->websocket_ok('/not_echo/307')->send_ok('hello')->message_ok->message_is('echo: hello')->finish_ok;
  $t->websocket_ok('/not_echo/303')->send_ok('hello')->message_ok->message_is('echo: hello')->finish_ok;
  $t->websocket_ok('/not_echo/302')->send_ok('hello')->message_ok->message_is('echo: hello')->finish_ok;
  $t->websocket_ok('/not_echo/301')->send_ok('hello')->message_ok->message_is('echo: hello')->finish_ok;
};

subtest 'Custom headers and protocols' => sub {
  my $headers = {DNT => 1, 'Sec-WebSocket-Key' => 'NTA2MDAyMDU1NjMzNjkwMg=='};
  $t->websocket_ok('/echo' => $headers => ['foo', 'bar', 'baz'])
    ->header_is('Sec-WebSocket-Accept'   => 'I+x5C3/LJxrmDrWw42nMP4pCSes=')
    ->header_is('Sec-WebSocket-Protocol' => undef)
    ->send_ok('hello')
    ->message_ok->message_is('echo: hello')->finish_ok;
  is $t->tx->req->headers->dnt,                    1,               'right "DNT" value';
  is $t->tx->req->headers->sec_websocket_protocol, 'foo, bar, baz', 'right "Sec-WebSocket-Protocol" value';
};

subtest 'Bytes' => sub {
  $t->websocket_ok('/echo')->send_ok({binary => 'bytes!'})->message_ok->message_is({binary => 'bytes!'})
    ->send_ok({binary => 'bytes!'})
    ->message_ok->message_isnt({text => 'bytes!'})->finish_ok;
};

subtest 'Bytes in multiple frames' => sub {
  $t->websocket_ok('/echo')
    ->send_ok([0, 0, 0, 0, 2, 'a'])
    ->send_ok([0, 0, 0, 0, 0, 'b'])
    ->send_ok([1, 0, 0, 0, 0, 'c'])
    ->message_ok->message_is({binary => 'abc'})->finish_ok;
};

subtest 'Zero' => sub {
  $t->websocket_ok('/echo')->send_ok(0)->message_ok->message_is('echo: 0')
    ->send_ok(0)
    ->message_ok->message_like({text => qr/0/})->finish_ok(1000)->finished_ok(1000);
};

subtest '64-bit binary message' => sub {
  $t->request_ok($t->ua->build_websocket_tx('/echo'));
  is $t->tx->max_websocket_size, 262144, 'right size';
  $t->tx->max_websocket_size(65538);
  $t->send_ok({binary => 'a' x 65538})->message_ok->message_is({binary => 'a' x 65538})->finish_ok->finished_ok(1005);
};

subtest '64-bit binary message (too large for server)' => sub {
  $t->websocket_ok('/echo')->send_ok({binary => 'b' x 65539})->finished_ok(1009);
};

subtest '64-bit binary message (too large for client)' => sub {
  $t->websocket_ok('/echo');
  $t->tx->max_websocket_size(65536);
  $t->send_ok({binary => 'c' x 65537})->finished_ok(1009);
};

subtest 'Binary message in two frames without FIN bit (too large for server)' => sub {
  $t->websocket_ok('/echo')
    ->send_ok([0, 0, 0, 0, 2, 'd' x 30000])
    ->send_ok([0, 0, 0, 0, 0, 'd' x 35539])
    ->finished_ok(1009);
};

subtest 'Plain alternative' => sub {
  $t->get_ok('/echo')->status_is(200)->content_is('plain echo!');
};

subtest 'Compression denied by the server' => sub {
  $t->websocket_ok('/no_compression' => {'Sec-WebSocket-Extensions' => 'permessage-deflate'});
  is $t->tx->req->headers->sec_websocket_extensions, 'permessage-deflate', 'right "Sec-WebSocket-Extensions" value';
  ok !$t->tx->compressed, 'WebSocket has no compression';
  $t->send_ok({binary => 'a' x 500})->message_ok->message_is({binary => 'a' x 500})->finish_ok;
};

subtest 'Compressed message ("permessage-deflate")' => sub {
  $t->websocket_ok('/echo' => {'Sec-WebSocket-Extensions' => 'permessage-deflate'});
  ok $t->tx->compressed, 'WebSocket has compression';
  $t->send_ok({binary => 'a' x 10000})->header_is('Sec-WebSocket-Extensions' => 'permessage-deflate');
  is $t->tx->req->headers->sec_websocket_extensions, 'permessage-deflate', 'right "Sec-WebSocket-Extensions" value';
  my $payload;
  $t->tx->once(
    frame => sub {
      my ($tx, $frame) = @_;
      $payload = $frame->[5];
    }
  );
  $t->message_ok->message_is({binary => 'a' x 10000});
  ok length $payload < 10000, 'message has been compressed';
  $t->finish_ok->finished_ok(1005);
};

subtest 'Timeout' => sub {
  $t->websocket_ok('/timeout')->send_ok('timeout')->message_ok->message_is('timeout: 30')
    ->send_ok('0')
    ->message_ok->message_is('0: 0')->send_ok('120')->message_ok->message_is('120: 120')->finish_ok;
};

subtest 'Compressed message exceeding the limit when decompressed' => sub {
  $t->websocket_ok('/echo' => {'Sec-WebSocket-Extensions' => 'permessage-deflate'})
    ->header_is('Sec-WebSocket-Extensions' => 'permessage-deflate')
    ->send_ok({binary => 'a' x 1000000})
    ->finished_ok(1009);
};

subtest "Huge message that doesn't compress very well" => sub {
  my $huge = join '', map { int rand(9) } 1 .. 65538;
  $t->websocket_ok('/echo' => {'Sec-WebSocket-Extensions' => 'permessage-deflate'})
    ->send_ok({binary => $huge})
    ->message_ok->message_is({binary => $huge})->finish_ok;
};

subtest 'Protocol negotiation' => sub {
  $t->websocket_ok('/protocols' => ['bar'])->message_ok->message_is('bar')->message_ok->message_is('bar')->finish_ok;
  is $t->tx->protocol,                             'bar', 'right protocol';
  is $t->tx->res->headers->sec_websocket_protocol, 'bar', 'right "Sec-WebSocket-Protocol" value';
  $t->websocket_ok('/protocols' => ['baz', 'bar', 'foo'])->message_ok->message_is('foo')->message_ok->message_is('foo')
    ->finish_ok;
  is $t->tx->protocol,                             'foo', 'right protocol';
  is $t->tx->res->headers->sec_websocket_protocol, 'foo', 'right "Sec-WebSocket-Protocol" value';
  $t->websocket_ok('/protocols' => ['0'])->message_ok->message_is('0')->message_ok->message_is('0')->finish_ok;
  is $t->tx->protocol,                             '0', 'right protocol';
  is $t->tx->res->headers->sec_websocket_protocol, '0', 'right "Sec-WebSocket-Protocol" value';
  $t->websocket_ok('/protocols' => [''])->message_ok->message_is('none')->message_ok->message_is('none')->finish_ok;
  is $t->tx->protocol, undef, 'no protocol';
  $t->websocket_ok('/protocols' => ['', '', ''])->message_ok->message_is('none')->message_ok->message_is('none')
    ->finish_ok;
  is $t->tx->protocol, undef, 'no protocol';
  $t->websocket_ok('/protocols')->message_ok->message_is('none')->message_ok->message_is('none')->finish_ok;
  is $t->tx->protocol, undef, 'no protocol';
};

subtest 'JSON roundtrips (with a lot of different tests)' => sub {
  $t->websocket_ok('/json')
    ->send_ok({json => {test => 23, snowman => '☃'}})
    ->message_ok->json_message_is('' => {test => 24, snowman => '☃'})
    ->json_message_is('' => {test => 24, snowman => '☃'})
    ->json_message_has('/test')
    ->json_message_hasnt('/test/2')
    ->send_ok({binary => encode_json([1, 2, 3])}, 'with description')
    ->message_ok('with description')
    ->message_is('[1,2,3,4]')
    ->message_is('[1,2,3,4]', 'with description')
    ->message_isnt('[1,2,3]')
    ->message_isnt('[1,2,3]', 'with description')
    ->message_like(qr/3/)
    ->message_like(qr/3/, 'with description')
    ->message_unlike(qr/5/)
    ->message_unlike(qr/5/, 'with description')
    ->json_message_is([1, 2, 3, 4])
    ->json_message_is([1, 2, 3, 4])
    ->send_ok({binary => encode_json([1, 2, 3])})
    ->message_ok->json_message_has('/2')
    ->json_message_has('/2', 'with description')
    ->json_message_hasnt('/5')
    ->json_message_hasnt('/5', 'with description')
    ->json_message_is('/2' => 3)
    ->json_message_is('/2' => 3, 'with description')
    ->send_ok({json => {'☃' => [1, 2, 3]}})
    ->message_ok->json_message_is('/☃', [1, 2, 3])
    ->json_message_like('/☃/1' => qr/\d/)
    ->json_message_like('/☃/2' => qr/3/, 'with description')
    ->json_message_unlike('/☃/1' => qr/[a-z]/)
    ->json_message_unlike('/☃/2' => qr/2/, 'with description')
    ->send_ok({json => 'works'})
    ->message_ok->json_message_is('works')->send_ok({json => undef})->message_ok->json_message_is(undef)->finish_ok;
};

subtest 'Plain request' => sub {
  $t->get_ok('/plain')->status_is(200)->content_is('Nothing to see here!');
};

subtest 'Server push' => sub {
  $t->websocket_ok('/push')->message_ok->message_is('push')->message_ok->message_is('push')
    ->message_ok->message_is('push')->finish_ok;
  $t->websocket_ok('/push')->message_ok->message_unlike(qr/shift/)->message_ok->message_isnt('shift')
    ->message_ok->message_like(qr/us/)->message_ok->message_unlike({binary => qr/push/})->finish_ok;
};

subtest 'Another plain request' => sub {
  $t->get_ok('/plain')->status_is(200)->content_is('Nothing to see here!');
};

subtest 'Multiple roundtrips' => sub {
  $t->websocket_ok('/echo')->send_ok('hello')->message_ok->message_is('echo: hello')->finish_ok;
  $t->websocket_ok('/echo')->send_ok('this')->send_ok('just')->send_ok('works')->message_ok->message_is('echo: this')
    ->message_ok->message_is('echo: just')->message_ok->message_is('echo: works')->message_like(qr/orks/)->finish_ok;
};

subtest 'Another plain request' => sub {
  $t->get_ok('/plain')->status_is(200)->content_is('Nothing to see here!');
};

subtest 'Unicode roundtrips' => sub {
  $t->websocket_ok('/unicode')->send_ok('hello')->message_ok->message_is('♥: hello')->finish_ok;
  $t->websocket_ok('/unicode')->send_ok('hello again')->message_ok->message_is('♥: hello again')
    ->send_ok('and one ☃ more time')
    ->message_ok->message_is('♥: and one ☃ more time')->finish_ok;
};

subtest 'Binary frame and events' => sub {
  my $bytes = b("I ♥ Mojolicious")->encode('UTF-16LE')->to_string;
  $t->websocket_ok('/bytes');
  my $binary;
  $t->tx->on(
    frame => sub {
      my ($ws, $frame) = @_;
      $binary++ if $frame->[4] == 2;
    }
  );
  my $close;
  $t->tx->on(finish => sub { shift; $close = [@_] });
  $t->send_ok({binary => $bytes})->message_ok->message_is($bytes);
  ok $binary, 'received binary frame';
  $binary = undef;
  $t->send_ok({text => $bytes})->message_ok->message_is($bytes);
  ok !$binary, 'received text frame';
  $t->finish_ok(1000 => 'Have a nice day!');
  is_deeply $close, [1000, 'Have a nice day!'], 'right status and message';
};

subtest 'Binary roundtrips' => sub {
  my $bytes = b("I ♥ Mojolicious")->encode('UTF-16LE')->to_string;
  $t->request_ok($t->ua->build_websocket_tx('/bytes'))->send_ok({binary => $bytes})->message_ok->message_is($bytes)
    ->send_ok({binary => $bytes})
    ->message_ok->message_is($bytes)->finish_ok;
};

subtest 'Two responses' => sub {
  $t->websocket_ok('/once')->send_ok('hello')->message_ok->message_is('ONE: hello')
    ->message_ok->message_is('TWO: hello')->send_ok('hello')->message_ok->message_is('ONE: hello')
    ->send_ok('hello')
    ->message_ok->message_is('ONE: hello')->finish_ok;
};

subtest 'WebSocket connection gets closed right away' => sub {
  $t->websocket_ok('/close')->finished_ok(1001);
};

subtest 'WebSocket connection gets closed after one message' => sub {
  $t->websocket_ok('/one_sided')->message_ok->message_is('I ♥ Mojolicious!')->finished_ok(1005);
};

subtest 'Nested WebSocket' => sub {
  $t->websocket_ok('/nested')->send_ok('hello')->message_ok->message_is('nested echo: hello')->finished_ok(1000);
};

subtest 'Test custom message' => sub {
  $t->message([binary => 'foobarbaz'])->message_like(qr/bar/)->message_is({binary => 'foobarbaz'});
};

subtest 'Nested WebSocket with cookie' => sub {
  $t->websocket_ok('/nested')->send_ok('hello')->message_ok->message_is('nested echo: helloagain')->finished_ok(1000);
};

subtest 'Nested plain request' => sub {
  $t->get_ok('/nested')->status_is(200)->content_is('plain nested!');
};

subtest 'Another nested plain request' => sub {
  $t->post_ok('/nested')->status_is(200)->content_is('plain nested too!');
};

done_testing();
