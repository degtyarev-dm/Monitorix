#
# Monitorix - A lightweight system monitoring tool.
#
# Copyright (C) 2005-2013 by Jordi Sanfeliu <jordi@fibranet.cat>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#

package port;

use strict;
use warnings;
use Monitorix;
use RRDs;
use POSIX qw(strftime);
use Exporter 'import';
our @EXPORT = qw(port_init port_update port_cgi);

sub port_init {
	my $myself = (caller(0))[3];
	my ($package, $config, $debug) = @_;
	my $rrd = $config->{base_lib} . $package . ".rrd";
	my $port = $config->{port};

	my $info;
	my @ds;
	my @tmp;
	my $n;

	if(-e $rrd) {
		$info = RRDs::info($rrd);
		for my $key (keys %$info) {
			if(index($key, 'ds[') == 0) {
				if(index($key, '.type') != -1) {
					push(@ds, substr($key, 3, index($key, ']') - 3));
				}
			}
		}
		if(scalar(@ds) / 4 != $port->{max}) {
			logger("$myself: Detected size mismatch between 'max = $port->{max}' and $rrd (" . scalar(@ds) / 4 . "). Resizing it accordingly. All historic data will be lost. Backup file created.");
			rename($rrd, "$rrd.bak");
		}
	}

	if(!(-e $rrd)) {
		logger("Creating '$rrd' file.");
		for($n = 0; $n < $port->{max}; $n++) {
			push(@tmp, "DS:port" . $n . "_i_in:GAUGE:120:0:U");
			push(@tmp, "DS:port" . $n . "_i_out:GAUGE:120:0:U");
			push(@tmp, "DS:port" . $n . "_o_in:GAUGE:120:0:U");
			push(@tmp, "DS:port" . $n . "_o_out:GAUGE:120:0:U");
		}
		eval {
			RRDs::create($rrd,
				"--step=60",
				@tmp,
				"RRA:AVERAGE:0.5:1:1440",
				"RRA:AVERAGE:0.5:30:336",
				"RRA:AVERAGE:0.5:60:744",
				"RRA:AVERAGE:0.5:1440:365",
				"RRA:MIN:0.5:1:1440",
				"RRA:MIN:0.5:30:336",
				"RRA:MIN:0.5:60:744",
				"RRA:MIN:0.5:1440:365",
				"RRA:MAX:0.5:1:1440",
				"RRA:MAX:0.5:30:336",
				"RRA:MAX:0.5:60:744",
				"RRA:MAX:0.5:1440:365",
				"RRA:LAST:0.5:1:1440",
				"RRA:LAST:0.5:30:336",
				"RRA:LAST:0.5:60:744",
				"RRA:LAST:0.5:1440:365",
			);
		};
		my $err = RRDs::error;
		if($@ || $err) {
			logger("$@") unless !$@;
			if($err) {
				logger("ERROR: while creating $rrd: $err");
				if($err eq "RRDs::error") {
					logger("... is the RRDtool Perl package installed?");
				}
			}
			return;
		}
	}

	if($config->{os} eq "Linux") {
		my $num;
		my @line;

		# set the iptables rules for each defined port
		my @pl = split(',', $port->{list});
		for($n = 0; $n < $port->{max}; $n++) {
			$pl[$n] = trim($pl[$n]);
			if($pl[$n]) {
				my $p = lc((split(',', $port->{desc}->{$pl[$n]}))[1]) || "all";
				my $conn = lc((split(',', $port->{desc}->{$pl[$n]}))[2]);
				if($conn =~ /in/ || $conn =~ /in\/out/) {
					system("iptables -N monitorix_IN_$n 2>/dev/null");
					system("iptables -I INPUT -p $p --sport 1024:65535 --dport $pl[$n] -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j monitorix_IN_$n -c 0 0");
					system("iptables -I OUTPUT -p $p --sport $pl[$n] --dport 1024:65535 -m conntrack --ctstate ESTABLISHED,RELATED -j monitorix_IN_$n -c 0 0");
				}
				if($conn =~ /out/ || $conn =~ /in\/out/) {
					system("iptables -N monitorix_OUT_$n 2>/dev/null");
					system("iptables -I INPUT -p $p --sport $pl[$n] --dport 1024:65535 -m conntrack --ctstate ESTABLISHED,RELATED -j monitorix_OUT_$n -c 0 0");
					system("iptables -I OUTPUT -p $p --sport 1024:65535 --dport $pl[$n] -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j monitorix_OUT_$n -c 0 0");
				}
				if($conn !~ /in/ && $conn !~ /out/) {
					logger("$myself: Invalid connection type '$conn'; must be 'in', 'out' or 'in/out'.");
				}
			}
		}
	}
	if(grep {$_ eq $config->{os}} ("FreeBSD", "OpenBSD", "NetBSD")) {
		# set the ipfw rules for each defined port
		my @pl = split(',', $port->{list});
		for($n = 0; $n < $port->{max}; $n++) {
			$pl[$n] = trim($pl[$n]);
			if($pl[$n]) {
				my $p = lc((split(',', $port->{desc}->{$pl[$n]}))[1]) || "all";
				# in/out support pending XXX
				system("ipfw -q add $port->{rule} count $p from me $pl[$n] to any");
				system("ipfw -q add $port->{rule} count $p from any to me $pl[$n]");
			}
		}
	}

	$config->{port_hist_in} = ();
	$config->{port_hist_out} = ();
	push(@{$config->{func_update}}, $package);
	logger("$myself: Ok") if $debug;
}

sub port_update {
	my $myself = (caller(0))[3];
	my ($package, $config, $debug) = @_;
	my $rrd = $config->{base_lib} . $package . ".rrd";
	my $port = $config->{port};

	my @i_in;
	my @i_out;
	my @o_in;
	my @o_out;

	my $n;
	my $rrdata = "N";

	if($config->{os} eq "Linux") {
		open(IN, "iptables -nxvL INPUT |");
		while(<IN>) {
			for($n = 0; $n < $port->{max}; $n++) {
				$i_in[$n] = 0 unless $i_in[$n];
				$o_in[$n] = 0 unless $o_in[$n];
				if(/ monitorix_IN_$n /) {
					my (undef, $bytes) = split(' ', $_);
					chomp($bytes);
					$i_in[$n] = $bytes - ($config->{port_hist_i_in}[$n] || 0);
					$i_in[$n] = 0 unless $i_in[$n] != $bytes;
					$config->{port_hist_i_in}[$n] = $bytes;
					$i_in[$n] /= 60;
				}
				if(/ monitorix_OUT_$n /) {
					my (undef, $bytes) = split(' ', $_);
					chomp($bytes);
					$o_in[$n] = $bytes - ($config->{port_hist_o_in}[$n] || 0);
					$o_in[$n] = 0 unless $o_in[$n] != $bytes;
					$config->{port_hist_o_in}[$n] = $bytes;
					$o_in[$n] /= 60;
				}
			}
		}
		close(IN);
		open(IN, "iptables -nxvL OUTPUT |");
		while(<IN>) {
			for($n = 0; $n < $port->{max}; $n++) {
				$o_out[$n] = 0 unless $o_out[$n];
				$i_out[$n] = 0 unless $i_out[$n];
				if(/ monitorix_OUT_$n /) {
					my (undef, $bytes) = split(' ', $_);
					chomp($bytes);
					$o_out[$n] = $bytes - ($config->{port_hist_o_out}[$n] || 0);
					$o_out[$n] = 0 unless $o_out[$n] != $bytes;
					$config->{port_hist_o_out}[$n] = $bytes;
					$o_out[$n] /= 60;
				}
				if(/ monitorix_IN_$n /) {
					my (undef, $bytes) = split(' ', $_);
					chomp($bytes);
					$i_out[$n] = $bytes - ($config->{port_hist_i_out}[$n] || 0);
					$i_out[$n] = 0 unless $i_out[$n] != $bytes;
					$config->{port_hist_i_out}[$n] = $bytes;
					$i_out[$n] /= 60;
				}
			}
		}
		close(IN);
	}
	if(grep {$_ eq $config->{os}} ("FreeBSD", "OpenBSD", "NetBSD")) {
		my @pl = split(',', $port->{list});
		open(IN, "ipfw show $port->{rule} 2>/dev/null |");
		while(<IN>) {
			for($n = 0; $n < $port->{max}; $n++) {
				$i_in[$n] = 0 unless $i_in[$n];
				$o_in[$n] = 0 unless $o_in[$n];
				$pl[$n] = trim($pl[$n]);
				if(/ from any to me dst-port $pl[$n]$/) {
					my (undef, undef, $bytes) = split(' ', $_);
					chomp($bytes);
					$i_in[$n] = $bytes - ($config->{port_hist_i_in}[$n] || 0);
					$i_in[$n] = 0 unless $i_in[$n] != $bytes;
					$config->{port_hist_i_in}[$n] = $bytes;
					$i_in[$n] /= 60;
				}
				$o_out[$n] = 0 unless $o_out[$n];
				$i_out[$n] = 0 unless $i_out[$n];
				if(/ from me $pl[$n] to any$/) {
					my (undef, undef, $bytes) = split(' ', $_);
					chomp($bytes);
					$i_out[$n] = $bytes - ($config->{port_hist_i_out}[$n] || 0);
					$i_out[$n] = 0 unless $i_out[$n] != $bytes;
					$config->{port_hist_i_out}[$n] = $bytes;
					$i_out[$n] /= 60;
				}
			}
		}
		close(IN);
	}

	for($n = 0; $n < $port->{max}; $n++) {
		$rrdata .= ":$i_in[$n]:$i_out[$n]:$o_in[$n]:$o_out[$n]";
	}
	RRDs::update($rrd, $rrdata);
	logger("$myself: $rrdata") if $debug;
	my $err = RRDs::error;
	logger("ERROR: while updating $rrd: $err") if $err;
}

sub port_cgi {
	my ($package, $config, $cgi) = @_;

	my $port = $config->{port};
	my $tf = $cgi->{tf};
	my $colors = $cgi->{colors};
	my $graph = $cgi->{graph};
	my $silent = $cgi->{silent};

	my $u = "";
	my $width;
	my $height;
	my @riglim;
	my @warning;
	my @PNG;
	my @PNGz;
	my $name;
	my @tmp;
	my @tmpz;
	my @CDEF;
	my $T = "B";
	my $vlabel = "bytes/s";
	my $n;
	my $n2;
	my $n3;
	my $str;
	my $err;

	my $rrd = $config->{base_lib} . $package . ".rrd";
	my $title = $config->{graph_title}->{$package};
	my $PNG_DIR = $config->{base_dir} . "/" . $config->{imgs_dir};

	$title = !$silent ? $title : "";

	if(lc($config->{netstats_in_bps}) eq "y") {
		$T = "b";
		$vlabel = "bits/s";
	}


	# text mode
	#
	if(lc($config->{iface_mode}) eq "text") {
		if($title) {
			main::graph_header($title, 2);
			print("    <tr>\n");
			print("    <td bgcolor='$colors->{title_bg_color}'>\n");
		}
		my (undef, undef, undef, $data) = RRDs::fetch("$rrd",
			"--start=-$tf->{nwhen}$tf->{twhen}",
			"AVERAGE",
			"-r $tf->{res}");
		$err = RRDs::error;
		print("ERROR: while fetching $rrd: $err\n") if $err;
		my $line1;
		my $line2;
		print("    <pre style='font-size: 12px; color: $colors->{fg_color}';>\n");
		print("    ");
		for($n = 0; $n < $port->{max} && $n < scalar(my @pl = split(',', $port->{list})); $n++) {
			$pl[$n] = trim($pl[$n]);
			my $pn = trim((split(',', $port->{desc}->{$pl[$n]}))[0]);
			my $pc = trim((split(',', $port->{desc}->{$pl[$n]}))[2]);
			foreach(split('/', $pc)) {
				printf("   %-5s %10s", $pl[$n], uc(trim($_)) . "-" . $pn);
				$line1 .= "    K$T/s_I   K$T/s_O";
				$line2 .= "-------------------";
			}
		}
		print("\n");
		print("Time$line1\n");
		print("----$line2 \n");
		my $line;
		my @row;
		my $time;
		my $n2;
		my $from;
		my $to;
		for($n = 0, $time = $tf->{tb}; $n < ($tf->{tb} * $tf->{ts}); $n++) {
			$line = @$data[$n];
			$time = $time - (1 / $tf->{ts});
			printf(" %2d$tf->{tc} ", $time);
			for($n2 = 0; $n2 < $port->{max} && $n2 < scalar(my @pl = split(',', $port->{list})); $n2++) {
				$pl[$n2] = trim($pl[$n2]);
				my $pc = trim((split(',', $port->{desc}->{$pl[$n2]}))[2]);
				$from = $n2 * 4;
				$to = $from + 3;
				my ($i_in, $i_out, $o_in, $o_out) = @$line[$from..$to];
				my $k_i_in = ($i_in || 0) / 1024;
				my $k_i_out = ($i_out || 0) / 1024;
				my $k_o_in = ($o_in || 0) / 1024;
				my $k_o_out = ($o_out || 0) / 1024;

				if(lc($config->{netstats_in_bps}) eq "y") {
					$k_i_in *= 8;
					$k_i_out *= 8;
					$k_o_in *= 8;
					$k_o_out *= 8;
				}
				foreach(split('/', $pc)) {
					if(lc($_) eq "in") {
						@row = ($k_i_in, $k_i_out);
						printf("   %6d   %6d ", @row);
					}
					if(lc($_) eq "out") {
						@row = ($k_o_in, $k_o_out);
						printf("   %6d   %6d ", @row);
					}
				}
			}
			print("\n");
		}
		print("    </pre>\n");
		if($title) {
			print("    </td>\n");
			print("    </tr>\n");
			main::graph_footer();
		}
		print("  <br>\n");
		return;
	}


	# graph mode
	#
	if($silent eq "yes" || $silent eq "imagetag") {
		$colors->{fg_color} = "#000000";  # visible color for text mode
		$u = "_";
	}
	if($silent eq "imagetagbig") {
		$colors->{fg_color} = "#000000";  # visible color for text mode
		$u = "";
	}

	my $max = max($port->{max}, scalar(my @pl = split(',', $port->{list})));
	for($n = 0; $n < $max; $n++) {
		$pl[$n] = trim($pl[$n]);
		my $pc = trim((split(',', $port->{desc}->{$pl[$n]}))[2]);
		foreach my $conn (split('/', $pc)) {
			$str = $u . $package . $n . substr($conn, 0 ,1) . "." . $tf->{when} . ".png";
			push(@PNG, $str);
			unlink("$PNG_DIR" . $str);
			if(lc($config->{enable_zoom}) eq "y") {
				$str = $u . $package . $n . substr($conn, 0 ,1) . "z." . $tf->{when} . ".png";
				push(@PNGz, $str);
				unlink("$PNG_DIR" . $str);
			}
		}
	}

	$n = $n3 = 0;
	$n2 = 1;
	while($n < $max) {
		if($title) {
			if($n == 0) {
				main::graph_header($title, $port->{graphs_per_row});
				print("    <tr>\n");
			}
		}

		my $pc = trim((split(',', $port->{desc}->{$pl[$n]}))[2]);
		foreach my $pcon (split('/', $pc)) {
			if($title) {
				print("    <td bgcolor='" . $colors->{title_bg_color} . "'>\n");
			}
			my $pnum;
			$pl[$n] = trim($pl[$n]);
			my $pn = trim((split(',', $port->{desc}->{$pl[$n]}))[0]);
			my $pp = trim((split(',', $port->{desc}->{$pl[$n]}))[1]);
			my $prig = trim((split(',', $port->{desc}->{$pl[$n]}))[3]);
			my $plim = trim((split(',', $port->{desc}->{$pl[$n]}))[4]);
			undef(@riglim);
			if(trim($prig) eq 1) {
				push(@riglim, "--upper-limit=" . trim($plim));
			} else {
				if(trim($prig) eq 2) {
					push(@riglim, "--upper-limit=" . trim($plim));
					push(@riglim, "--rigid");
				}
			}
			undef(@warning);
			if($config->{os} eq "Linux") {
				open(IN, "netstat -nl --$pp |");
				while(<IN>) {
					(undef, undef, undef, $pnum) = split(' ', $_);
					chomp($pnum);
					$pnum =~ s/.*://;
					if($pnum eq $pl[$n]) {
						last;
					}
				}
				close(IN);
			}
			if(grep {$_ eq $config->{os}} ("FreeBSD", "OpenBSD")) {
				open(IN, "netstat -anl -p $pp |");
				while(<IN>) {
					 my $stat;
					(undef, undef, undef, $pnum, undef, $stat) = split(' ', $_);
					chomp($stat);
					if($stat eq "LISTEN") {
						chomp($pnum);
						($pnum) = ($pnum =~ m/^.*?(\.\d+$)/);
						$pnum =~ s/\.//;
						if($pnum eq $pl[$n]) {
							last;
						}
					}
				}
				close(IN);
			}
			if($pnum ne $pl[$n]) {
				push(@warning, $colors->{warning_color});
			}

			$name = substr(uc($pcon) . "-" . $pn, 0, 15);
			undef(@tmp);
			undef(@tmpz);
			undef(@CDEF);
			if(lc($pcon) eq "in") {
				push(@tmp, "AREA:B_i_in#44EE44:Input");
				push(@tmp, "AREA:B_i_out#4444EE:Output");
				push(@tmp, "AREA:B_i_out#4444EE:");
				push(@tmp, "AREA:B_i_in#44EE44:");
				push(@tmp, "LINE1:B_i_out#0000EE");
				push(@tmp, "LINE1:B_i_in#00EE00");
				push(@tmpz, "AREA:B_i_in#44EE44:Input");
				push(@tmpz, "AREA:B_i_out#4444EE:Output");
				push(@tmpz, "AREA:B_i_out#4444EE:");
				push(@tmpz, "AREA:B_i_in#44EE44:");
				push(@tmpz, "LINE1:B_i_out#0000EE");
				push(@tmpz, "LINE1:B_i_in#00EE00");
				if(lc($config->{netstats_in_bps}) eq "y") {
					push(@CDEF, "CDEF:B_i_in=i_in,8,*");
					push(@CDEF, "CDEF:B_i_out=i_out,8,*");
				} else {
					push(@CDEF, "CDEF:B_i_in=i_in");
					push(@CDEF, "CDEF:B_i_out=i_out");
				}
			}
			if(lc($pcon) eq "out") {
				push(@tmp, "AREA:B_o_in#44EE44:Input");
				push(@tmp, "AREA:B_o_out#4444EE:Output");
				push(@tmp, "AREA:B_o_out#4444EE:");
				push(@tmp, "AREA:B_o_in#44EE44:");
				push(@tmp, "LINE1:B_o_out#0000EE");
				push(@tmp, "LINE1:B_o_in#00EE00");
				push(@tmpz, "AREA:B_o_in#44EE44:Input");
				push(@tmpz, "AREA:B_o_out#4444EE:Output");
				push(@tmpz, "AREA:B_o_out#4444EE:");
				push(@tmpz, "AREA:B_o_in#44EE44:");
				push(@tmpz, "LINE1:B_o_out#0000EE");
				push(@tmpz, "LINE1:B_o_in#00EE00");
				if(lc($config->{netstats_in_bps}) eq "y") {
					push(@CDEF, "CDEF:B_o_in=o_in,8,*");
					push(@CDEF, "CDEF:B_o_out=o_out,8,*");
				} else {
					push(@CDEF, "CDEF:B_o_in=o_in");
					push(@CDEF, "CDEF:B_o_out=o_out");
				}
			}
			($width, $height) = split('x', $config->{graph_size}->{mini});
			if($silent =~ /imagetag/) {
				($width, $height) = split('x', $config->{graph_size}->{remote}) if $silent eq "imagetag";
				($width, $height) = split('x', $config->{graph_size}->{main}) if $silent eq "imagetagbig";
				push(@tmp, "COMMENT: \\n");
				push(@tmp, "COMMENT: \\n");
				push(@tmp, "COMMENT: \\n");
			}
			RRDs::graph("$PNG_DIR" . "$PNG[$n3]",
				"--title=$name traffic  ($tf->{nwhen}$tf->{twhen})",
				"--start=-$tf->{nwhen}$tf->{twhen}",
				"--imgformat=PNG",
				"--vertical-label=$vlabel",
				"--width=$width",
				"--height=$height",
				@riglim,
				"--lower-limit=0",
				@{$cgi->{version12}},
				@{$cgi->{version12_small}},
				@{$colors->{graph_colors}},
				@warning,
				"DEF:i_in=$rrd:port" . $n . "_i_in:AVERAGE",
				"DEF:i_out=$rrd:port" . $n . "_i_out:AVERAGE",
				"DEF:o_in=$rrd:port" . $n . "_o_in:AVERAGE",
				"DEF:o_out=$rrd:port" . $n . "_o_out:AVERAGE",
				@CDEF,
				@tmp);
			$err = RRDs::error;
			print("ERROR: while graphing $PNG_DIR" . "$PNG[$n3]: $err\n") if $err;
			if(lc($config->{enable_zoom}) eq "y") {
				($width, $height) = split('x', $config->{graph_size}->{zoom});
				RRDs::graph("$PNG_DIR" . "$PNGz[$n3]",
					"--title=$name traffic  ($tf->{nwhen}$tf->{twhen})",
					"--start=-$tf->{nwhen}$tf->{twhen}",
					"--imgformat=PNG",
					"--vertical-label=$vlabel",
					"--width=$width",
					"--height=$height",
					@riglim,
					"--lower-limit=0",
					@{$cgi->{version12}},
					@{$cgi->{version12_small}},
					@{$colors->{graph_colors}},
					@warning,
					"DEF:i_in=$rrd:port" . $n . "_i_in:AVERAGE",
					"DEF:i_out=$rrd:port" . $n . "_i_out:AVERAGE",
					"DEF:o_in=$rrd:port" . $n . "_o_in:AVERAGE",
					"DEF:o_out=$rrd:port" . $n . "_o_out:AVERAGE",
					@CDEF,
					@tmpz);
				$err = RRDs::error;
				print("ERROR: while graphing $PNG_DIR" . "$PNGz[$n3]: $err\n") if $err;
			}
			if($title || ($silent =~ /imagetag/ && $graph =~ /port$n3/)) {
				if(lc($config->{enable_zoom}) eq "y") {
					if(lc($config->{disable_javascript_void}) eq "y") {
						print("      <a href=\"" . $config->{url} . "/" . $config->{imgs_dir} . $PNGz[$n3] . "\"><img src='" . $config->{url} . "/" . $config->{imgs_dir} . $PNG[$n3] . "' border='0'></a>\n");
					}
					else {
						print("      <a href=\"javascript:void(window.open('" . $config->{url} . "/" . $config->{imgs_dir} . $PNGz[$n3] . "','','width=" . ($width + 115) . ",height=" . ($height + 100) . ",scrollbars=0,resizable=0'))\"><img src='" . $config->{url} . "/" . $config->{imgs_dir} . $PNG[$n3] . "' border='0'></a>\n");
					}
				} else {
					print("      <img src='" . $config->{url} . "/" . $config->{imgs_dir} . $PNG[$n3] . "'>\n");
				}
			}
			if($title) {
				print("    </td>\n");
			}

			if($n2 < $port->{graphs_per_row} && $n2 < $max) {
				$n2++;
			} else {
				if($title) {
					print("    </tr>\n");
					print("    <tr>\n");
				}
				$n2 = 1;
			}
			$n3++;
		}
		$n++;
	}
	if($title) {
		main::graph_footer();
	}
	print("  <br>\n");
	return;
}

1;
