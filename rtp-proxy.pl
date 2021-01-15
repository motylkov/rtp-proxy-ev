#!/usr/bin/perl

use FindBin '$Bin';
use strict;
use warnings;
use EV;
use POSIX qw(setgid setuid);
use IO::Socket::INET6;
use Socket6;
use Time::HiRes qw(usleep);
use File::Path qw( make_path );
use File::Basename;
use Net::RTP::Packet;
use YAML::XS;


sub LoadConfig {
    my $ConfigFile = shift;
    return YAML::XS::LoadFile($ConfigFile);
}

our $config = LoadConfig($Bin.'/etc/rtp-proxy.cfg');

my $time = time();
my $p_ref;
my $calls_ref;

my $p_tmp = $config->{'rtp_proxy'}->{'rtp_port_from'};
for ($config->{'rtp_proxy'}->{'rtp_port_from'}..$config->{'rtp_proxy'}->{'rtp_port_to'}) {
    $p_ref->{$p_tmp} = 0;
    $p_tmp++;
}
my $rtp_addr = undef;
#$rtp_addr = $config->{'rtp_proxy'}->{'rtp_addr'};

our $RunUid = (getpwnam($config->{'rtp_proxy'}->{'user'}))[2];
our $RunGid = (getgrnam($config->{'rtp_proxy'}->{'group'}))[2];


sub SetProcUidGid {
    my $uid = shift;
    my $gid = shift;

    if (defined($gid) && $gid =~ /^\d+$/) {
        setgid($gid) or die "Cannot switch gid: $!";
    }
    if (defined($uid) && $uid =~ /^\d+$/) {
        setuid($uid) or die "Cannot switch uid: $!";
    }
}


sub WritePid {
    my $FileName = shift;
    
    my $Pid = $$;
    $FileName .= ".".$Pid;

    my $dir = dirname($FileName);
    if (!(-d $dir)) {
        printf("Create pid path: '%s'\n", $dir);
        make_path($dir);
    }

    my $fh = new IO::Handle;
    if (!open($fh, '>', $FileName)) {
        warn("WritePid error: $!");
    } else {
        print $fh $Pid;
        close($fh);
    }
}


my $sock_ctrl = IO::Socket::INET6->new(ReuseAddr => 1, Listen => 1, LocalPort => $config->{'rtp_proxy'}->{'cmd_port'}) || die($!);
my $w = EV::io($sock_ctrl, EV::READ, \&ctrl_incoming);

our $rtp_h;
our $ctrl_h;


sub GetRtpPort {
    foreach (keys(%{$p_ref})) {
        return $_ if ($p_ref->{$_} == 0);
    }
    return undef;
}
sub LeaseRtpPort {
    my $RtpPort = shift;
    $p_ref->{$RtpPort} = 1;
}
sub ReLeaseRtpPort {
    my $RtpPort = shift;
    $p_ref->{$RtpPort} = 0;
}

sub StopProxyCallTag {
    my $call_id = shift;
    my $tag = shift;
    if (defined($calls_ref->{$call_id}) && defined($calls_ref->{$call_id}->{$tag})) {
        $calls_ref->{$call_id}->{$tag}->{'hdl'}->close() if (defined($calls_ref->{$call_id}->{$tag}->{'hdl'}));
        delete($rtp_h->{$calls_ref->{$call_id}->{$tag}->{'hdl'}}) if (defined($calls_ref->{$call_id}->{$tag}->{'hdl'}));
        ReLeaseRtpPort($calls_ref->{$call_id}->{$tag}->{'rtp_LocalPort'}) if (defined($calls_ref->{$call_id}->{$tag}->{'rtp_LocalPort'}));
        delete($calls_ref->{$call_id}->{$tag});
    }
}


sub IpAddrPortPack {
    my $ip_addr = shift;
    my $ip_port = shift;
    return undef if ($ip_port !~ /^\d+$/ || $ip_port <= 0 || $ip_port > 65535);

    if (!defined($ip_addr)) {
        return pack_sockaddr_in6($ip_port, inet_pton(AF_INET6, '::'));
    }
    if (!defined($ip_addr) || $ip_addr =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
        return pack_sockaddr_in($ip_port, inet_pton(AF_INET, $ip_addr));
    }
    if ($ip_addr =~ /^.*:.*:.*$/) {
        return pack_sockaddr_in6($ip_port, inet_pton(AF_INET6, $ip_addr));
    }
}


sub ctrl_incoming {
    my ($w, $revents) = @_;
    my $fh = $w->fh->accept or die($!);
    $ctrl_h->{$fh} = EV::io($fh, EV::READ, \&ctrl_client);
}


sub ctrl_client {
    my ($w, $revents) = @_;
    my $fh = $w->fh;
    return if (!exists($ctrl_h->{$fh}));

    my $src_addr = $fh->peerhost();
    my $src_port = $fh->peerport();
    my $dst_addr = $fh->sockhost();
    my $dst_port = $fh->sockport();

    my $inStr;
    my $rb = sysread($fh, $inStr, 2048);
    if ($rb) {
        chomp($inStr);
        if ($inStr =~ /^[ULDQ] /) {
            ### IS CMD
            my @cmd = split(/ /, $inStr);
            my $call_id = $cmd[1];
            if ($cmd[0] eq 'U') { ### Initiator RTP
                my $ftag = $cmd[4];
                if (defined($ftag) && $ftag =~ /^.+$/) {
                    if (!defined($calls_ref->{$call_id}->{$ftag}) || !defined($calls_ref->{$call_id}->{$ftag}->{'rtp_PeerAddr_sdp'}) || !defined($calls_ref->{$call_id}->{$ftag}->{'rtp_PeerPort_sdp'}) || $calls_ref->{$call_id}->{$ftag}->{'rtp_PeerAddr_sdp'} ne $cmd[2] || $calls_ref->{$call_id}->{$ftag}->{'rtp_PeerPort_sdp'} ne $cmd[3]) {
                        StopProxyCallTag($call_id, $ftag);
                        $calls_ref->{$call_id}->{$ftag}->{'rtp_LocalAddr'} = $rtp_addr;
                        $calls_ref->{$call_id}->{$ftag}->{'rtp_LocalPort'} = GetRtpPort();
                        $calls_ref->{$call_id}->{$ftag}->{'rtp_PeerAddr_sdp'} = $cmd[2];
                        $calls_ref->{$call_id}->{$ftag}->{'rtp_PeerPort_sdp'} = $cmd[3];
                        $calls_ref->{$call_id}->{$ftag}->{'cli_addr_sdp'} = IpAddrPortPack($calls_ref->{$call_id}->{$ftag}->{'rtp_PeerAddr_sdp'}, $calls_ref->{$call_id}->{$ftag}->{'rtp_PeerPort_sdp'});
                        $calls_ref->{$call_id}->{$ftag}->{'time_init'} = $time;
                        $calls_ref->{$call_id}->{$ftag}->{'rtp'} = new Net::RTP::Packet();
                        $calls_ref->{$call_id}->{$ftag}->{'hdl'} = OpenUdpSocket($calls_ref->{$call_id}->{$ftag}->{'rtp_LocalAddr'}, $calls_ref->{$call_id}->{$ftag}->{'rtp_LocalPort'});
                        LeaseRtpPort($calls_ref->{$call_id}->{$ftag}->{'rtp_LocalPort'});
                    }
                    syswrite($fh, $calls_ref->{$call_id}->{$ftag}->{'rtp_LocalPort'});
                } else {
                    syswrite($fh, 'ERROR');
                }
            }
            if ($cmd[0] eq 'L') { ### Responder RTP
                my $ftag = $cmd[4];
                my $ttag = $cmd[5];
                if (defined($ftag) && $ftag =~ /^.+$/ && defined($ttag) && $ttag =~ /^.+$/) {
                    if (!defined($calls_ref->{$call_id}->{$ftag})) {
                        syswrite($fh, 'ERROR: no such ftag');
                    } else {
                        if (!defined($calls_ref->{$call_id}->{$ttag}) || !defined($calls_ref->{$call_id}->{$ttag}->{'rtp_PeerAddr_sdp'}) || !defined($calls_ref->{$call_id}->{$ttag}->{'rtp_PeerPort_sdp'}) || $calls_ref->{$call_id}->{$ttag}->{'rtp_PeerAddr_sdp'} ne $cmd[2] || $calls_ref->{$call_id}->{$ttag}->{'rtp_PeerPort_sdp'} ne $cmd[3]) {
                            StopProxyCallTag($call_id, $ttag);
                            $calls_ref->{$call_id}->{$ttag}->{'rtp_LocalAddr'} = $rtp_addr;
                            $calls_ref->{$call_id}->{$ttag}->{'rtp_LocalPort'} = GetRtpPort();
                            $calls_ref->{$call_id}->{$ttag}->{'rtp_PeerAddr_sdp'} = $cmd[2];
                            $calls_ref->{$call_id}->{$ttag}->{'rtp_PeerPort_sdp'} = $cmd[3];
                            $calls_ref->{$call_id}->{$ttag}->{'cli_addr_sdp'} = IpAddrPortPack($calls_ref->{$call_id}->{$ttag}->{'rtp_PeerAddr_sdp'}, $calls_ref->{$call_id}->{$ttag}->{'rtp_PeerPort_sdp'});
                            $calls_ref->{$call_id}->{$ttag}->{'time_init'} = $time;
                            $calls_ref->{$call_id}->{$ttag}->{'rtp'} = new Net::RTP::Packet();
                            $calls_ref->{$call_id}->{$ttag}->{'hdl'} = OpenUdpSocket($calls_ref->{$call_id}->{$ttag}->{'rtp_LocalAddr'}, $calls_ref->{$call_id}->{$ttag}->{'rtp_LocalPort'});
                            LeaseRtpPort($calls_ref->{$call_id}->{$ttag}->{'rtp_LocalPort'});

                            $calls_ref->{$call_id}->{$ttag}->{'hdl'}->send($calls_ref->{$call_id}->{$ttag}->{'rtp'}->encode(), 0, $calls_ref->{$call_id}->{$ftag}->{'cli_addr_sdp'});
                            $calls_ref->{$call_id}->{$ftag}->{'hdl'}->send($calls_ref->{$call_id}->{$ftag}->{'rtp'}->encode(), 0, $calls_ref->{$call_id}->{$ttag}->{'cli_addr_sdp'});

                            $rtp_h->{$calls_ref->{$call_id}->{$ftag}->{'hdl'}} = EV::io($calls_ref->{$call_id}->{$ftag}->{'hdl'}, EV::READ, sub {
                                rtp_incoming($calls_ref->{$call_id}->{$ftag}, $calls_ref->{$call_id}->{$ttag}, @_);
                            });
                            $rtp_h->{$calls_ref->{$call_id}->{$ttag}->{'hdl'}} = EV::io($calls_ref->{$call_id}->{$ttag}->{'hdl'}, EV::READ, sub {
                                rtp_incoming($calls_ref->{$call_id}->{$ttag}, $calls_ref->{$call_id}->{$ftag}, @_);
                            });
                        }
                        syswrite($fh, $calls_ref->{$call_id}->{$ttag}->{'rtp_LocalPort'});
                    }
                } else {
                    syswrite($fh, 'ERROR');
                }
            }
            if ($cmd[0] eq 'D') { ### Stop RTP
                my $ftag = $cmd[2];
                my $ttag = $cmd[3];
                StopProxyCallTag($call_id, $ftag) if (defined($ftag));
                StopProxyCallTag($call_id, $ttag) if (defined($ttag));
                syswrite($fh, 'OK');
            }
            if ($cmd[0] eq 'Q') { ### Info about RTP
                my $ftag = $cmd[2];
                my $ttag = $cmd[3];
                my $ftag_ok = undef;
                my $ttag_ok = undef;
                $ftag_ok = 1 if (defined($calls_ref->{$call_id}) && defined($calls_ref->{$call_id}->{$ftag}->{'hdl'}));
                $ttag_ok = 1 if (defined($calls_ref->{$call_id}) && defined($calls_ref->{$call_id}->{$ttag}->{'hdl'}));
                if ($ftag_ok && $ttag_ok) {
                    #print "Call OK\n";
                    syswrite($fh, 'OK');
                } else {
                    #print "Call ERROR\n";
                    syswrite($fh, 'E8');
                }
            }
        } else {
            ###
            syswrite($fh, 'ERROR');
        }
    }

    $fh->close;
    undef($w);
    delete($ctrl_h->{$fh});
}


my ($rtp_RecvBytes, $rtp_RecvBuf);
sub rtp_incoming {
    my ($in, $out, $w, $revents) = @_;
    my $fh = $w->fh;
    return if (!exists($rtp_h->{$fh}));

    $rtp_RecvBytes = $fh->recv($rtp_RecvBuf, 2048);
    if ($rtp_RecvBytes) {
        $in->{'time_mod'} = $time;
        $in->{'rtp_LocalAddr'} = $fh->sockhost() if (!defined($in->{'rtp_LocalAddr'}));
        $in->{'rtp_LocalPort'} = $fh->sockport() if (!defined($in->{'rtp_LocalPort'}));
        $in->{'rtp_PeerAddr'} = $fh->peerhost() if (!defined($in->{'rtp_PeerAddr'}));
        $in->{'rtp_PeerPort'} = $fh->peerport() if (!defined($in->{'rtp_PeerPort'}));
        $in->{'srv_addr'} = IpAddrPortPack($in->{'rtp_LocalAddr'}, $in->{'rtp_LocalPort'}) if (!defined($in->{'srv_addr'}));
        $in->{'cli_addr'} = IpAddrPortPack($in->{'rtp_PeerAddr'}, $in->{'rtp_PeerPort'}) if (!defined($in->{'cli_addr'}));

        if (defined($out->{'cli_addr'}) && defined($out->{'srv_addr'})) {
            $out->{'hdl'}->send($rtp_RecvBuf, 0, $out->{'cli_addr'});
        } elsif (defined($out->{'cli_addr_sdp'})) {
            $out->{'hdl'}->send($rtp_RecvBuf, 0, $out->{'cli_addr_sdp'});
        }
    }
    return 1;
}


sub OpenUdpSocket {
    my $LocalAddr = shift;
    my $LocalPort = shift;
    #my $PeerAddr = shift;
    #my $PeerPort = shift;

    my $udpsock = IO::Socket::INET6->new(
        LocalAddr => $LocalAddr,
        LocalPort => $LocalPort,
        #PeerAddr => $PeerAddr,
        #PeerPort => $PeerPort,
        Proto => 'udp',
        ReuseAddr => '1'
    ) || warn($!);
    binmode($udpsock);
    return $udpsock;
}


sub RtpProxyProc {
    my $pid = fork();
    if ($pid) {
        # PARENT
        #exit();
    } elsif ($pid == 0) {
        $0 = $config->{'rtp_proxy'}->{'process_name'} if (defined($config->{'rtp_proxy'}->{'process_name'}));
        WritePid($config->{'rtp_proxy'}->{'pid_file'});
        SetProcUidGid($RunUid, $RunGid);
        EV::loop();
    }
}


my $Test_timer = EV::periodic(0, 5, 0, sub {
    foreach (keys(%{$calls_ref})) {
        my $call_id = $_;
        my $cid_ok = 0;
        foreach (keys(%{$calls_ref->{$call_id}})) {
            if (defined($calls_ref->{$call_id}->{$_}->{'time_init'})) {
                $cid_ok = 1;
                last;
            }
        }
        delete($calls_ref->{$call_id}) if (!$cid_ok);
    }
    
    foreach (keys(%{$calls_ref})) {
        my $call_id = $_;
        foreach (keys(%{$calls_ref->{$call_id}})) {
            my $tag = $_;
            my $row = $calls_ref->{$call_id}->{$tag};
            my $time_init = 0;
            $time_init = $calls_ref->{$call_id}->{$tag}->{'time_init'} if (defined($calls_ref->{$call_id}->{$tag}->{'time_init'}));
            my $time_mod = 0;
            $time_mod = $calls_ref->{$call_id}->{$tag}->{'time_mod'} if (defined($calls_ref->{$call_id}->{$tag}->{'time_mod'}));
            StopProxyCallTag($call_id, $tag) if ($time_mod == 0 && $time >= $time_init + 180);
            StopProxyCallTag($call_id, $tag) if ($time_mod > 0 && $time >= $time_mod + 10);
        }
    }
});


my $Time_timer = EV::periodic(0, 1, 0, sub {
    $time = time();
});


if ($config->{'rtp_proxy'}->{'background'}) {
    RtpProxyProc();
}

__END__

