#!/usr/bin/perl
#
#  Copyright (c) 2011-2023 FastMail Pty Ltd. All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in
#     the documentation and/or other materials provided with the
#     distribution.
#
#  3. The name "Fastmail Pty Ltd" must not be used to
#     endorse or promote products derived from this software without
#     prior written permission. For permission or any legal
#     details, please contact
#      FastMail Pty Ltd
#      PO Box 234
#      Collins St West 8007
#      Victoria
#      Australia
#
#  4. Redistributions of any form whatsoever must retain the following
#     acknowledgment:
#     "This product includes software developed by Fastmail Pty. Ltd."
#
#  FASTMAIL PTY LTD DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
#  INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY  AND FITNESS, IN NO
#  EVENT SHALL OPERA SOFTWARE AUSTRALIA BE LIABLE FOR ANY SPECIAL, INDIRECT
#  OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
#  USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
#  TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
#  OF THIS SOFTWARE.
#

package Cassandane::Cyrus::Notify;
use strict;
use warnings;
use DateTime;
use Data::Dumper;

use lib '.';
use base qw(Cassandane::Cyrus::TestCase);
use Cassandane::Util::Log;

sub new
{
    my $class = shift;
    my $config = Cassandane::Config->default()->clone();
    $config->set(imapidlepoll => 2);
    return $class->SUPER::new({
        config => $config,
        deliver => 1,
        start_instances => 0,
    }, @_);
}

sub set_up
{
    my ($self) = @_;
    $self->SUPER::set_up();
}

sub tear_down
{
    my ($self) = @_;
    $self->SUPER::tear_down();
}

sub test_message
    :needs_component_idled :min_version_3_9
{
    my ($self) = @_;

    xlog $self, "Message test of the NOTIFY command (idled required)";

    $self->{instance}->{config}->set(imapidlepoll => '2');
    $self->{instance}->add_start(name => 'idled',
                                 argv => [ 'idled' ]);
    $self->{instance}->start();

    my $svc = $self->{instance}->get_service('imap');

    my $store = $svc->create_store();
    my $talk = $store->get_client();

    my $otherstore = $svc->create_store();
    my $othertalk = $otherstore->get_client();

    xlog $self, "The server should report the NOTIFY capability";
    $self->assert($talk->capability()->{notify});

    xlog $self, "Create two mailboxes";
    $talk->create("INBOX.foo");
    $talk->create("INBOX.bar");

    xlog $self, "Deliver a message";
    my $msg = $self->{gen}->generate(subject => "Message 1");
    $self->{instance}->deliver($msg);

    xlog $self, "Examine INBOX.foo";
    $talk->examine("INBOX.foo");

    xlog $self, "Enable Notify";
    my $res = $talk->_imap_cmd('NOTIFY', 0, 'STATUS', 'SET', 'STATUS',
                               "(SELECTED (MessageNew" .
                               " (UID BODY.PEEK[HEADER.FIELDS (From Subject)])" .
                               " MessageExpunge FlagChange))",
                               "(PERSONAL (MessageNew MessageExpunge))");

    # Should get STATUS responses for unselected mailboxes
    my $status = $talk->get_response_code('status');
    $self->assert_num_equals(1, $status->{'INBOX'}{messages});
    $self->assert_num_equals(2, $status->{'INBOX'}{uidnext});
    $self->assert_num_equals(0, $status->{'INBOX.bar'}{messages});
    $self->assert_num_equals(1, $status->{'INBOX.bar'}{uidnext});

    xlog $self, "Deliver a message";
    $msg = $self->{gen}->generate(subject => "Message 2");
    $self->{instance}->deliver($msg);

    # Should get STATUS response for INBOX
    $res = $store->idle_response('STATUS', 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no more unsolicited responses");

    $status = $talk->get_response_code('status');
    $self->assert_num_equals(2, $status->{'INBOX'}{messages});
    $self->assert_num_equals(3, $status->{'INBOX'}{uidnext});

    xlog $self, "EXPUNGE message from INBOX in other session";
    $othertalk->select("INBOX");
    $res = $othertalk->store('1', '+flags', '(\\Deleted)');
    $res = $othertalk->expunge();

    # Should get STATUS response for INBOX
    $res = $store->idle_response('STATUS', 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no more unsolicited responses");

    $status = $talk->get_response_code('status');
    $self->assert_num_equals(1, $status->{'INBOX'}{messages});
    $self->assert_num_equals(3, $status->{'INBOX'}{uidnext});

    xlog $self, "Select INBOX";
    $talk->examine("INBOX");

    xlog $self, "Deliver a message";
    $msg = $self->{gen}->generate(subject => "Message 3");
    $self->{instance}->deliver($msg);

    # Should get EXISTS, RECENT, FETCH response
    $res = $store->idle_response({}, 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response('FETCH', 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no more unsolicited responses");

    $self->assert_num_equals(2, $talk->get_response_code('exists'));
    $self->assert_num_equals(1, $talk->get_response_code('recent'));

    my $fetch = $talk->get_response_code('fetch');
    $self->assert_num_equals(3, $fetch->{2}{uid});
    $self->assert_str_equals('Message 3', $fetch->{2}{headers}{subject}[0]);
    $self->assert_not_null($fetch->{2}{headers}{from});

    xlog $self, "DELETE message from INBOX in other session";
    $res = $othertalk->store('1', '+flags', '(\\Deleted)');

    # Should get FETCH response for INBOX
    $res = $store->idle_response('FETCH', 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no more unsolicited responses");

    $fetch = $talk->get_response_code('fetch');
    $self->assert_num_equals(2, $fetch->{1}{uid});
    $self->assert_str_equals('\\Deleted', $fetch->{1}{flags}[0]);

    xlog $self, "EXPUNGE message from INBOX in other session";
    $res = $othertalk->expunge();

    # Should get EXPUNGE response for INBOX
    $res = $store->idle_response('EXPUNGE', 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no more unsolicited responses");

    $self->assert_num_equals(1, $talk->get_response_code('expunge'));

    xlog $self, "Disable Notify";
    $res = $talk->_imap_cmd('NOTIFY', 0, "", "NONE");

    xlog $self, "Deliver a message";
    $msg = $self->{gen}->generate(subject => "Message 4");
    $self->{instance}->deliver($msg);

    # Should get no unsolicited responses
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no unsolicited responses");
}

sub test_mailbox
    :needs_component_idled :min_version_3_9
{
    my ($self) = @_;

    xlog $self, "Mailbox test of the NOTIFY command (idled required)";

    $self->{instance}->{config}->set(imapidlepoll => '2');
    $self->{instance}->add_start(name => 'idled',
                                 argv => [ 'idled' ]);
    $self->{instance}->start();

    my $svc = $self->{instance}->get_service('imap');

    my $store = $svc->create_store();
    my $talk = $store->get_client();

    my $otherstore = $svc->create_store();
    my $othertalk = $otherstore->get_client();

    xlog $self, "The server should report the NOTIFY capability";
    $self->assert($talk->capability()->{notify});

    xlog $self, "Enable Notify";
    my $res = $talk->_imap_cmd('NOTIFY', 0, "", "SET",
                               "(PERSONAL (MailboxName SubscriptionChange))");

    xlog $self, "Create mailbox in other session";
    $othertalk->create("INBOX.rename-me");

    # Should get LIST response
    $res = $store->idle_response('LIST', 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no more unsolicited responses");

    my $list = $talk->get_response_code('list');
    $self->assert_str_equals('INBOX.rename-me', $list->[0][2]);

    xlog $self, "Subscribe mailbox in other session";
    $othertalk->subscribe("INBOX.rename-me");

    # Should get LIST response with \Subscribed
    $res = $store->idle_response('LIST', 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no more unsolicited responses");

    $list = $talk->get_response_code('list');
    $self->assert_str_equals('\\Subscribed', $list->[0][0][0]);
    $self->assert_str_equals('INBOX.rename-me', $list->[0][2]);

    xlog $self, "Rename mailbox in other session";
    $othertalk->rename("INBOX.rename-me", "INBOX.delete-me");

    # Use our own handler since IMAPTalk will lose OLDNAME
    my %handlers =
    (
        list => sub
        {
            my (undef, $data) = @_;
            $list = [ $data ];
        },
    );

    # Should get LIST response with OLDNAME
    $res = $store->idle_response(\%handlers, 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no more unsolicited responses");

    $self->assert_str_equals('INBOX.delete-me', $list->[0][2]);
    $self->assert_str_equals('OLDNAME', $list->[0][3][0]);
    $self->assert_str_equals('INBOX.rename-me', $list->[0][3][1][0]);

    xlog $self, "Delete mailbox in other session";
    $othertalk->delete("INBOX.delete-me");

    # Should get LIST response with \NonExistent
    $res = $store->idle_response({}, 3);
    $self->assert($res, "received an unsolicited response");
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no more unsolicited responses");

    $list = $talk->get_response_code('list');
    $self->assert_str_equals('\\NonExistent', $list->[0][0][0]);
    $self->assert_str_equals('INBOX.delete-me', $list->[0][2]);

    xlog $self, "Disable Notify";
    $res = $talk->_imap_cmd('NOTIFY', 0, "", "NONE");

    xlog $self, "Create mailbox in other session";
    $othertalk->create("INBOX.foo");

    # Should get no unsolicited responses
    $res = $store->idle_response({}, 1);
    $self->assert(!$res, "no unsolicited responses");
}

1;
