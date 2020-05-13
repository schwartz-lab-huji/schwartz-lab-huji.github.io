#!/usr/bin/perl -w

use strict;
use IO::File;
use Getopt::Long;
use List::Util qw/min max/;
autoflush STDOUT 1;

use warnings FATAL => 'all';

# A regular expression of a word.
use constant WORD_RE => qr/^[a-z\_\$]++$/;

# Split token (to separate words and punctuation)
use constant SPLIT_TOKEN => "[ \t]++|\\b";

# A (fake) enum of word types:
use constant HFW => 1;
use constant CW => 0;
use constant NO_WORD => -1;

use constant CW_SYMBOL => "CW";

use constant MIN_PATT_LENGTH => 3;
sub main(@) {
        my $if;
        my $n_hfws=1000;
        my $n_cws=10000;
        my $of;
        my $m_thr = 0.05;
        my $top_m_thr = 0.05;
		my $max_pattern_length = 5;
		my $min_num_of_edges_per_pattern =  5000;
		my $n_pattern_candidates = 5000;
		my $top_n_lines = 1000000;
		my $min_edge_frequency = 3;
		my $merge_sps;
		my $lc;

        usage({
                "if=s"			=> \$if,
				"lc+"			=> \$lc,
                "m_thr=f"      	=> \$m_thr,	
				"max_pattern_length=i"		=> \$max_pattern_length,
				"merge_sps+"			=> \$merge_sps,
				"min_edge_frequency=i"		=> \$min_edge_frequency,
				"min_num_of_edges_per_pattern=i"	=> \$min_num_of_edges_per_pattern,
                "n_cws=i"		=> \$n_cws,
                "n_hfws=i"		=> \$n_hfws,
				"n_pattern_candidates=i"	=> \$n_pattern_candidates,
                "of=s"			=> \$of,
				"top_n_lines=i"	=> \$top_n_lines,
        }, ["if=s", "of=s"]);

		# First, generate a HFW/CW dictionary.
		print "Generating HFW/CW dictionary from $if.\n";
		my ($hfw_dict, $cws) = gen_HFW_dict($if, $n_hfws, $n_cws, $lc, $top_n_lines);
		
		my $pattern_candidates;
		
		# Now, get list of symmetric pattern candidates.
		print "Getting symmetric pattern candidates.\n";
		$pattern_candidates = get_pattern_candidates($if, $hfw_dict, $cws, $max_pattern_length, $n_pattern_candidates, $lc, $top_n_lines);
		
		# Third, collect edges for all pattern candidates.
		print "Getting pattern edges.\n";
		my $pattern_edges = read_pattern_edges($if, $hfw_dict, $cws, $pattern_candidates, $min_num_of_edges_per_pattern, $max_pattern_length, $lc);
		
		# Fourth, select symmetric patterns.
		print "Selecting symmetric patterns.\n";
		my $selected_patterns = select_sps($pattern_edges, $min_edge_frequency, $m_thr);
		
		# Merge SPs that contain other SPs (e.g., "between CW and CW" contains "CW and CW", so we omit it.
		if (defined $merge_sps) {
			print "Merging patterns\n";
			$selected_patterns = merge_sps($selected_patterns);
		}

		
		# Last, write selected patterns to output file.
		print "Writing selected patterns to $of\n";
		write_sps($of, $selected_patterns);

        return 0;
}

sub merge_sps($) {
	my $sps = shift;
	
	my @sps = keys %$sps;
	
	my %selected_sps;
	
	foreach my $i (0 .. $#sps) {
		my $good = 1;
		foreach my $j (0 .. $#sps) {
			next if $i == $j;
			
			if ($sps[$i] =~ /$sps[$j]/) {
				print "$sps[$i] contains $sps[$j]. Skipping it.\n";
				$good=0;
			}
		}
		
		if ($good) {
			$selected_sps{$sps[$i]} = $sps->{$sps[$i]};
		}
	}
	
	return \%selected_sps;
}

# Traverse input file and select high frequency words.
sub gen_HFW_dict($$$$$) {
	my $if = shift;
	my $n_hfws = shift;
	my $n_cws = shift;
	my $lc = shift;
	my $top_n_lines = shift;
	
	my %vocab;
	
	my $line_ctr = 0;
	my $word_counter = 0;
	
	
	# First, generate a unigram dictionary.
	my $ifh = new IO::File($if) or die "Cannot open $if for reading";
	
	while (my $line = $ifh->getline() and (not defined $top_n_lines or $line_ctr < $top_n_lines)) {
		if (++$line_ctr % 100000 == 0) {
			printf("%.1fM %c", $line_ctr/1000000, 13);
		}
		chomp($line);
		if (defined $lc) {
			$line = lc($line);
		}

		my @words = split(SPLIT_TOKEN, $line);
		
		foreach my $w (@words) {
			next unless $w =~ WORD_RE;
			
			
			$word_counter++;
			$vocab{$w}++
		}
	}
	
	$ifh->close();
	
	print "\nRead $line_ctr lines and ".scalar(keys %vocab)." words\n";
	# Now, leave only high frequency words.
	my %hfws;
	
	my $n_words = 0;
	my %cws;
	foreach my $k (sort {$vocab{$b} <=> $vocab{$a}} keys %vocab) {
		if (++$n_words < $n_hfws) {
			$hfws{$k} = $vocab{$k}/$word_counter;
		} elsif ($n_words < $n_cws) {
			$cws{$k} = 1;
		} else {
			last;
		}
	}
	
	return (\%hfws, \%cws);
}

# Traverse input file and select high frequency pattern candidates with exactly 2 context words.
sub get_pattern_candidates($$$$$$$) {
	my $if = shift;
	my $hfw_dict = shift;
	my $cws = shift;
	my $max_pattern_length = shift;
	my $n_pattern_candidates = shift;
	my $lc = shift;
	my $top_n_lines = shift;
	
	my %dict;
	
	my $line_ctr = 0;
	
	# First, generate a pattern dictionary.
	my $ifh = new IO::File($if) or die "Cannot open $if for reading";
	
	while (my $line = $ifh->getline() and (not defined $top_n_lines or $line_ctr < $top_n_lines)) {
		if (++$line_ctr % 100000 == 0) {
			printf("%.1fM %c", $line_ctr/1000000, 13);
		}

		extract_patterns($line, $lc, $max_pattern_length, $hfw_dict, $cws, \&add_pattern_instance_func, \%dict);
	}
	
	$ifh->close();
	print "\n";
	# Now, leave only patterns with high enough frequency.
	my %patterns;
	
	print "Found ".scalar(keys %dict). " patterns.\n";

	my $n_patterns = 0;

	foreach my $k (sort {$dict{$b} <=> $dict{$a}} keys %dict) {
		$patterns{$k} = $dict{$k}/$line_ctr;
		
		last if ++$n_patterns == $n_pattern_candidates;
	}
	
	return \%patterns;
} 


sub extract_patterns($$$$$$$) {
	my $line = shift;
	my $lc = shift;
	my $max_pattern_length = shift;
	my $hfw_dict = shift;
	my $cws = shift;
	my $func = shift;
	my $dict = shift;

	chomp($line);

	if (defined $lc) {
		$line = lc($line);
	}
	
	my @words = split(SPLIT_TOKEN, $line);
	
	my @types;
	
	foreach my $w (@words) {
		if (exists $hfw_dict->{$w}) {
			push(@types, HFW);
		} elsif ($w !~ WORD_RE or not exists $cws->{$w}) {
			push(@types, NO_WORD);
		} else {
			push(@types, CW);
		}
	}
	
	if (@words < MIN_PATT_LENGTH) {
		return;
	}
	my $end = @words - MIN_PATT_LENGTH + 1;
	
	for (my $i = 0 ; $i < $end ; ++$i) {
		my @cws;
		my @patt_words;
		my $has_hfw=0;
		my $stop = 0;

		# First, take the first MIN_PATT_LENGTH-1 words that must appear in each pattern.
		foreach my $k ($i .. $i + MIN_PATT_LENGTH-2) {
			if ($types[$k] == NO_WORD) {
				# No point trying longer patterns, as we reached a non-word.
				$stop = 1;
				
				# Starting next pattern search in the next letter after the NO_WORD char.
				$i = $k+1;
				last;
			} elsif ($types[$k] == CW) {
				# If both CWs are identical, stopping.
				if (@cws == 1 and $words[$k] eq $cws[0]) {
					$stop=1;
					last;
				}
				push(@cws, $words[$k]);
				push(@patt_words, CW_SYMBOL);
			} else {
				push(@patt_words, $words[$k]);
				$has_hfw = 1;
			}
		}
		next if $stop;
			
		my $end2 = min($i+$max_pattern_length-1, $#words);

		foreach my $k ($i + MIN_PATT_LENGTH - 1 .. $end2) {
			if ($types[$k] == NO_WORD) {
				# No point trying longer patterns, as we reached a non-word.
				last;
			} elsif ($types[$k] == CW) {
				# Each pattern candidate must have exactly 2 CWs.
				if (@cws == 2) {
					# No point trying longer patterns, as we already have 3 cws here.
					$stop = 1;
					last;
				# If both CWs are identical, stopping.					
				} elsif (@cws == 1 and $words[$k] eq $cws[0]) {
					last;
				}

				push(@cws, $words[$k]);
				push(@patt_words, CW_SYMBOL);
			} else {
				push(@patt_words, $words[$k]);
				$has_hfw = 1;
			}
			
			# This pattern has 2 CWs: check if it as a candidate.
			if (@cws == 2 and $has_hfw) {
				my $str = join(" ", @patt_words);
	
				$func->($dict, $str, \@cws);
			}					
		}
	}
}

sub add_pattern_instance_func($$$) {
	my $dict = shift;
	my $str = shift;
	my $extra_param = shift;
	
	$dict->{$str}++;	
}

sub add_edges_func($$$) {
	my $dict = shift;
	my $str = shift;
	my $extra_param = shift;
	
	if (exists $dict->{$str}) {
		unless (exists $dict->{$str}->{$extra_param->[0]}) {
			$dict->{$str}->{$extra_param->[0]} = {};
		}
		
		$dict->{$str}->{$extra_param->[0]}->{$extra_param->[1]}++;
	}
}


# Traverse input file and extract edges for each pattern candidate.
sub read_pattern_edges($$$$$$) {
	my $if = shift;
	my $hfw_dict = shift;
	my $cws = shift;
	my $pattern_candidates = shift;
	my $min_num_of_edges_per_pattern = shift;
	my $max_pattern_length = shift;
	my $lc = shift;
	
	my $line_ctr = 0;
	
	my %pattern_edges = map {$_ => {}} keys %$pattern_candidates;
	
	# First, generate a pattern dictionary.
	my $ifh = new IO::File($if) or die "Cannot open $if for reading";
	
	while (my $line = $ifh->getline()) {
		chomp($line);
		if (++$line_ctr % 100000 == 0) {
			printf("%.1fM %c", $line_ctr/1000000, 13);
		}

		extract_patterns($line, $lc, $max_pattern_length, $hfw_dict, $cws, \&add_edges_func, \%pattern_edges);
	}
	
	$ifh->close();
	
	print "\n";
	
	foreach my $k (keys %pattern_edges) {
		if (compute_n_edges($pattern_edges{$k}) < $min_num_of_edges_per_pattern) {
			delete $pattern_edges{$k};
		}
	}
	
	return \%pattern_edges;
} 

sub compute_n_edges($) {
	my $patt = shift;
	
	my $n = 0;
	
	foreach my $k (keys %$patt) {
		$n += scalar (keys %{$patt->{$k}});
	}
	
	return $n;
}

# Compute m measure for each pattern candidate.
sub select_sps($$$) {
	my $pattern_edges = shift;
	my $min_edge_frequency = shift;
	my $m_thr = shift;
	
	my %m_measures;
	foreach my $patt (keys %$pattern_edges) {
		my $m = compute_m($pattern_edges->{$patt}, $min_edge_frequency);
		
		if ($m >= $m_thr) {
			$m_measures{$patt} = $m;
		}
	}
	
	return \%m_measures;
}

# Compute m measure for a single pattern candidate.
sub compute_m($$$) {
	my $edges = shift;
	my $min_edge_frequency = shift;
	
	my $n_symmetric_edges = 0;
	my $n_asymmetric_edges = 0;
	
	foreach my $w1 (keys %$edges) {
		foreach my $w2 (keys %{$edges->{$w1}}) {
			next if $edges->{$w1}->{$w2} < $min_edge_frequency;
			
			if (exists $edges->{$w2} and exists $edges->{$w2}->{$w1} and $edges->{$w2}->{$w1} >= $min_edge_frequency) {
				$n_symmetric_edges++;
			} else {
				$n_asymmetric_edges++;
			}
		}
	}
	
	if ($n_symmetric_edges == 0) {
		return 0;
	}
	
	# Each symmetric edge is counted twice, so dividing number of these edges by half.
	$n_symmetric_edges /= 2;
	
	my $m = $n_symmetric_edges/($n_symmetric_edges+$n_asymmetric_edges);
	
	return $m;
}

sub write_sps($$) {
	my $of = shift;
	my $select_sps = shift;
	
	my $ofh = new IO::File(">$of") or die "Cannot open $of for writing";
	
	foreach my $k (sort {$select_sps->{$b} <=> $select_sps->{$a}} keys %$select_sps) {
		$ofh->print("$k\n");
	}
	
	$ofh->close();
}


sub usage($$) {
        my $options = shift;
        my $mandatory = shift;
        my $help;

        foreach my $k (@$mandatory) {
                if (ref $k eq "ARRAY") {
                        foreach my $k2 (@$k) {
                                unless (exists $options->{$k2}) {
                                        die "Mandatory option $k2 is not optional\n";
                                }
                        }
                } elsif (not exists $options->{$k}) {
                        die "Mandatory option $k is not optional\n";
                }
        }


        $options->{"h+"} = \$help;

        my $result = GetOptions(%$options);


        if (not $result or $help) {
                getopt_gen_message($options, $mandatory);
        }

        foreach my $k (@$mandatory) {
                if (ref $k eq "ARRAY") {
                        my $found = 0;
                        foreach my $k2 (@$k) {
                               if (defined ${$options->{$k2}}) {
                                        $found = 1;
                                        last;
                                }
                        }

                        unless ($found) {
                                getopt_gen_message($options, $mandatory);
                        }
                } elsif (not defined ${$options->{$k}}) {
                        getopt_gen_message($options, $mandatory);
                }
        }
}

sub getopt_gen_message($$) {
        my $options = shift;
        my $mandatory = shift;

        print $0."\n";

        foreach my $k (sort {$a cmp $b} keys %$options) {
                print "-$k";
                if (defined ${$options->{$k}}) {
                        print " (${$options->{$k}})";
                }

                foreach my $field (@$mandatory) {
                        if ($field eq $k and not defined ${$options->{$k}}) {
                                print " [MANDATORY]";
                        }
                }
                print "\n";
        }

        die "\n";
}


exit(main(@ARGV));
