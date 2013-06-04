#!/usr/bin/perl

# mt-aws-glacier - Amazon Glacier sync client
# Copyright (C) 2012-2013  Victor Efimov
# http://mt-aws.com (also http://vs-dev.com) vs@vs-dev.com
# License: GPLv3
#
# This file is part of "mt-aws-glacier"
#
#    mt-aws-glacier is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    mt-aws-glacier is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.


use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/../", "$FindBin::RealBin/../../lib";
use File::Temp;
use Carp;
use URI;
use TestUtils;
use Test::More;
use File::Temp ();
warning_fatal();

my $test_size = 3_000_000 - 1;

my ($base) = initialize_processes();
	plan tests => 26;

	my $TEMP = File::Temp->newdir();
	my $mtroot = $TEMP->dirname();

	my $tmpfile = "$mtroot/lwp.tmp";
	
	
	sub make_glacier_request
	{
		my ($method, $url, $glacier_options, $merge_keys) = @_;
		my $g = App::MtAws::GlacierRequest->new($glacier_options);
		$g->{$_} = $merge_keys->{$_} for (keys %$merge_keys);
		$g->{method} = $method;
		$g->{url} = '/'.$url;
		local $ENV{MTGLACIER_FAKE_HOST} = $base;
		my $resp = eval {
			$g->perform_lwp();
		};
		return $resp ? ($g, $resp, undef) : ($g, undef, $@);
	}
	
	sub httpd_content_length
	{
	    my($c, $req, $size, $header_size) = @_;
	    $c->send_basic_header(200);
	    
	    my $s = 'x' x $size;
	    print $c "Content-Length: $header_size\015\012";
	    $c->send_crlf;
	    print $c $s;
	}
	
	sub httpd_empty_response
	{
	    my($c, $req, $size, $header_size) = @_;
	    $c->send_basic_header(200);
	}
	
	sub httpd_without_content_length
	{
	    my($c, $req, $size) = @_;
		my $resp = HTTP::Response->new(200, 'Fine');
		my $sent = 0;
		# force chunked-response
		$resp->content(sub {
			if (!$sent) {
				$sent = 1;
				return 'x' x $size;
			} else {
				return '';
			}
		});
		$c->send_response($resp);
	}
	
	# success with size defined
	{
		open F, ">$tmpfile";
		close F;
		my $writer = App::MtAws::HttpFileWriter->new(tempfile => $tmpfile);
		my (undef, $resp, undef) = make_glacier_request('GET', "content_length/$test_size/$test_size", {region => 'r', key => 'k', secret => 's', protocol => 'http'},
			{writer => $writer, expected_size => $test_size});
		is -s $tmpfile, $test_size;
		ok($resp->is_success);
	}
	
	# success with no size defined
	{
		open F, ">$tmpfile";
		close F;
		my $writer = App::MtAws::HttpFileWriter->new(tempfile => $tmpfile);
		my (undef, $resp, undef) = make_glacier_request('GET', "content_length/$test_size/$test_size", {region => 'r', key => 'k', secret => 's', protocol => 'http'},
			{writer => $writer});
		is -s $tmpfile, $test_size;
		ok($resp->is_success);
	}
	
	# truncated response, no size is defined
	{
		no warnings 'redefine';
		local *App::MtAws::GlacierRequest::_max_retries = sub { 1 };
		local *App::MtAws::GlacierRequest::_sleep = sub { };
		my $writer = App::MtAws::HttpFileWriter->new(tempfile => $tmpfile);
		my ($g, $resp, $err) = make_glacier_request('GET', "content_length/".($test_size-1)."/$test_size", {region => 'r', key => 'k', secret => 's', protocol => 'http'},
			{writer => $writer});
		is $err->{code}, 'too_many_tries'; # TODO: test with cmp_deep and exception()
		is $g->{last_retry_reason}, 'Unexpected end of data';
		is -s $tmpfile, $test_size;
	}
	
	# truncated response, size is defined
	{
		no warnings 'redefine';
		local *App::MtAws::GlacierRequest::_max_retries = sub { 1 };
		local *App::MtAws::GlacierRequest::_sleep = sub { };
		my $writer = App::MtAws::HttpFileWriter->new(tempfile => $tmpfile);
		my ($g, $resp, $err) = make_glacier_request('GET', "content_length/".($test_size-1)."/$test_size", {region => 'r', key => 'k', secret => 's', protocol => 'http'},
			{writer => $writer, expected_size => $test_size});
		is $err->{code}, 'too_many_tries'; # TODO: test with cmp_deep and exception()
		is $g->{last_retry_reason}, 'Unexpected end of data';
		is -s $tmpfile, $test_size;
	}

	# correct response, expected size is wrong
	{
		open F, ">$tmpfile";
		close F;
		no warnings 'redefine';
		local *App::MtAws::GlacierRequest::_max_retries = sub { 1 };
		local *App::MtAws::GlacierRequest::_sleep = sub { };
		my $writer = App::MtAws::HttpFileWriter->new(tempfile => $tmpfile);
		my ($g, $resp, $err) = make_glacier_request('GET', "content_length/$test_size/$test_size", {region => 'r', key => 'k', secret => 's', protocol => 'http'},
			{writer => $writer, expected_size => $test_size+1});
		is $err->{code}, 'wrong_file_size_in_journal'; # TODO: test with cmp_deep and exception()
		is -s $tmpfile, 0;
	}
	
	# correct response, size is zero
	{
		no warnings 'redefine';
		local *App::MtAws::GlacierRequest::_sleep = sub { die };
		for (qw/GET PUT POST DELETE/) {
			my ($g, $resp, $err) = make_glacier_request($_, "empty_response", {region => 'r', key => 'k', secret => 's', protocol => 'http'}, {});
			ok $resp && !$err, "empty response should work for $_ method";
		}
	}

	# data truncated, writer not used 
	{
		no warnings 'redefine';
		local *App::MtAws::GlacierRequest::_max_retries = sub { 1 };
		local *App::MtAws::GlacierRequest::_sleep = sub { };
		for (qw/GET PUT POST DELETE/) {
			my ($g, $resp, $err) = make_glacier_request($_, "content_length/499/501", {region => 'r', key => 'k', secret => 's', protocol => 'http'}, {});
			is $err->{code}, 'too_many_tries', $_;
			is $g->{last_retry_reason}, 'Unexpected end of data', "Reason for $_";
		}
	}

	# correct response, no size header sent (chunked response? or maybe http/1.0)
	{
		open F, ">$tmpfile";
		close F;
		no warnings 'redefine';
		local *App::MtAws::GlacierRequest::_max_retries = sub { 1 };
		local *App::MtAws::GlacierRequest::_sleep = sub { };
		my $writer = App::MtAws::HttpFileWriter->new(tempfile => $tmpfile);
		my ($g, $resp, $err) = make_glacier_request('GET', "without_content_length/$test_size", {region => 'r', key => 'k', secret => 's', protocol => 'http'},
			{writer => $writer, expected_size => $test_size});
		is $err->{code}, 'wrong_file_size_in_journal';
		is -s $tmpfile, 0;
	}

	sub httpd_quit
	{
	    my($c) = @_;
	    $c->send_error(503, "Bye, bye");
	    exit;  # terminate HTTP server
	}
	
	my $ua = new LWP::UserAgent;
	my $req = new HTTP::Request GET => "http://$base/quit";
	my $resp = $ua->request($req);

sub initialize_processes
{
	if (@ARGV && $ARGV[0] eq 'daemon') {
		require HTTP::Daemon;
		my $d = HTTP::Daemon->new(Timeout => 10, LocalAddr => '127.0.0.1');
		$SIG{PIPE}='IGNORE';
		$| = 1;
		print "Please to meet you at: <URL:", $d->url, ">\n";

		while (my $c = $d->accept) {
		my $r = $c->get_request;
		if ($r) {
			my @p = $r->uri->path_segments;
			shift @p;
			my $p = shift @p;
			my $func = lc("httpd_$p");
			if (defined &$func) {
				no strict 'refs';
				&$func($c, $r, @p);
		    } else {
				$c->send_error(404);
			}
		}
		$c = undef;  # close connection
		}
		print STDERR "HTTP Server terminated\n";
		exit;
	} else {
		use Config;
		my $perl = $Config{'perlpath'};
		open(DAEMON, "'$perl' $0 daemon |") or die "Can't exec daemon: $!";
		my $greeting = <DAEMON>;
		$greeting =~ m!<URL:http://([^/]+)/>! or die;
		my $base = $1;
		require LWP::UserAgent;
		require HTTP::Request;
		require App::MtAws::GlacierRequest;
		require App::MtAws;
		return $base;
	}
}

1;
