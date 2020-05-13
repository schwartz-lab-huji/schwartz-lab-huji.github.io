#!/usr/local/bin/perl -w

#########################################################################
#																		#
#	This script takes a corpus of plain text and a set of 				#
#	patterns and generates input files to the word2vec toolkit.			#
#																		#
#	Author: Roy Schwartz (roys02@cs.huji.ac.il)							#
#																		#
#########################################################################



use strict;
use IO::File;
use warnings FATAL => 'all';
STDOUT->autoflush;

use List::Util qw(sum);

use constant CW_SYMBOL => "CW";
use constant PATT_STR => "PATT";

use constant PATT_ELEMENTS_SEPERATOR => "-";
use constant HIGH_FREQUENCY_THR => 0.002;
use constant MIN_FREQ => 100;

sub add_patt_instance($$$$$$$$);

sub main(@) {
	my $hfw_thr = 0.0001;
	
	my $input_files = shift;
	my $patterns_input_file = shift;
	my $context_pairs_output_file = shift;
	my $word_vocabularty_output_file = shift;
	my $context_vocabularty_output_file = shift or die "Usage: $0 <input files (comma separated)> <patterns input file (one pattern per line)> <context pairs output file> <word vocab output file> <context vocab output file> <word count -- optional>\n";
	
	my $word_count_file;
	
	if (@_) {
		$word_count_file = shift;
	}

	# Read patterns into a Trie data structure.
	my $patterns_trie = read_patterns_trie($patterns_input_file);

	my %word_vocab;
	my %context_vocab;
	
	my @ifs = split("[,% ]", $input_files);
	
	# Now generate a list of content words which are considered as wildcard candidates.
	my ($cws) = get_cws($word_count_file, \@ifs);

	my $ofh = new IO::File(">$context_pairs_output_file") or die "Can't open $context_pairs_output_file for writing";
		
	my $n_lines = 0;
	
	# Traverse input files.
	foreach my $if (@ifs) {
		my $n_lines = 0;
		print "Reading $if\n";
		my $ifh = new IO::File($if);
		
		unless ($ifh) {
			warn "Cannot open $if for reading";
			next;
		}
		
		while (my $line = $ifh->getline()) {
			if (++$n_lines % 10000 == 0) {
				printf("%dK %c", $n_lines/1000, 13);
			}

			chomp($line);
			$line = lc($line);
            
            my @words = split("[ \t]++|\\b", $line);
			
			# Search for patterns starting at each word in the sentence.
			for (my $start = 0 ; $start < @words - 2 ; ++$start) {
				add_patt_instance(\@words, $start, 0, $patterns_trie, $cws, $ofh, \%word_vocab, \%context_vocab);
			}
		}
		
		$ifh->close();

		print "\n";
	}
	
	$ofh->close();

	# Writing word and context vocabularies.
	write_vocab(\%word_vocab, $word_vocabularty_output_file);
	write_vocab(\%context_vocab, $context_vocabularty_output_file);
	
	return 0;
}


# Write vocabulary to file.
sub write_vocab($$) {
	my $vocab = shift;
	my $of = shift;
	
	my @sorted_vocab = sort {$vocab->{$b} <=> $vocab->{$a}} keys %$vocab;
	
	my $ofh = new IO::File(">$of");
	
	unless ($ofh) {
		warn "Can't open $of for writing";
		return;
	}
	
	# Add dummy </s> node.
	$ofh->print("<\/s> 0\n");
	
	foreach my $k (@sorted_vocab) {
		$ofh->print("$k $vocab->{$k}\n");
	}
	
	$ofh->close();
}


# Read patterns from file and generate a Trie dataset.
sub read_patterns_trie($) {
	my $patterns_input_file = shift;
	
	print "Reading patterns from $patterns_input_file\n";
	
    my $ifh = new IO::File($patterns_input_file) or die "Cannot open $patterns_input_file for reading";
        
	my %trie;
	
	my $n_patts = 0;
	while (my $patt = $ifh->getline()) {
		$n_patts++;
		chomp($patt);
		my @elements = split(PATT_ELEMENTS_SEPERATOR, $patt);
		
		# wildcard indices.
		my @cw_indices;
		my $local_trie = \%trie;
		foreach my $i (0 .. $#elements - 1) {
			if ($elements[$i] eq CW_SYMBOL) {
				push(@cw_indices, $i);
			}
			unless (exists ($local_trie->{$elements[$i]})) {
				$local_trie->{$elements[$i]} = {};
			}
			
			$local_trie = $local_trie->{$elements[$i]};
		}
		
		if ($elements[$#elements] eq CW_SYMBOL) {
			push(@cw_indices, $#elements);
		}
		
		unless (exists $local_trie->{$elements[$#elements]}) {
			$local_trie->{$elements[$#elements]} = {};
		}
		
		$local_trie->{$elements[$#elements]}->{PATT_STR} = [$patt, \@cw_indices];
	}
	
	$ifh->close();
	
	print "Read $n_patts patterns\n";
	return \%trie;
}

# Add pattern instance to statistics.
sub add_patt_instance($$$$$$$$) {
	my $elements = shift;
	my $start = shift;
	my $patt_index = shift;
	my $patterns_trie = shift;
	my $cws = shift;
	my $ofh = shift;
	my $word_vocab = shift;
	my $context_vocab = shift;

	# Pattern found.
	if (exists $patterns_trie->{PATT_STR}) {
		my ($orig_patt_str, $cw_indices) = @{$patterns_trie->{PATT_STR}};

		# Pattern found!
		my @elements = @$elements[map {$_ + $start - $patt_index} @$cw_indices];
		$word_vocab->{$elements[0]}++;
		$context_vocab->{$elements[1]}++;
		$word_vocab->{$elements[1]}++;
		$context_vocab->{$elements[0]."_r"}++;
		$ofh->print($elements[0]." ".$elements[1]."\n");
		
		$word_vocab->{$elements[1]}++;
		$elements[0] .= "_r";
		
		$context_vocab->{$elements[0]}++;

		$ofh->print($elements[1]." ".$elements[0]."\n");
	} 
	
	# Recursion break condition.
	if ($start == @$elements) {
		return;
	 # Return if word is empty of punctuation.
	} elsif ($elements->[$start] =~ /^[^a-z]++$/ or not length($elements->[$start])) {
		return;
	}

	# Next word could either be one of the words the continues a pattern, or a wildcard.
	if (exists $patterns_trie->{$elements->[$start]}) {
		add_patt_instance($elements, $start+1, $patt_index+1, $patterns_trie->{$elements->[$start]}, $cws, $ofh, $word_vocab, $context_vocab);
	} elsif (not $elements->[$start] =~ /^[^a-z]++$/ and exists $cws->{$elements->[$start]} and exists $patterns_trie->{${\CW_SYMBOL}}) {
		add_patt_instance($elements, $start+1, $patt_index+1, $patterns_trie->{${\CW_SYMBOL}}, $cws, $ofh, $word_vocab, $context_vocab);
	} 
}


# Get a list of content words. High freqent words and low frequent words are discarded.
sub get_cws($$) {
	my $word_count_file = shift;
	my $ifs = shift;
	
	my %stats;
	
	my $n_words = 0;
	my $n_sent = 0;
	
	if (defined $word_count_file) {
		print "Reading unigram counts from $word_count_file\n";
		# Read high frequency words list from word count file.
		my $ifh = new IO::File($word_count_file) or die "Canot open $word_count_file for reading";
	
		while (my $line = $ifh->getline()) {
			chomp($line);
			my ($w,$c) = split("[ \t]++", $line);
			
			$stats{$w} = $c;
		}
		
		$ifh->close();
		
		$n_words = sum(values %stats);
	} else {
		print "Generating word count\n";
		
		# Generate list from text.
		foreach my $if (@$ifs) {
			print "Reading $if\n";
			my $ifh = new IO::File($if);
			
			unless ($ifh) {
				warn "Can't open $if for reading";
				next;
			}
			
			while (my $line = $ifh->getline()) {
				
				if (++$n_sent % 10000 == 0) {
					printf("%dK %c", $n_sent/1000, 13);
				}
				
				# Randomly skip 90% of the sentences to get an even distribution of the data.
				chomp($line);
				my @words = split(" ", $line);
				
				foreach my $w (@words) {
					# Skip empty words and punctuation.
					next if ($w =~ /^[^a-z]++$/ or not length($w));
					$stats{$w}++;
					$n_words++;
				}
			}
			
			$ifh->close();
		}
	}	
	
	my @sorted_words = sort {$stats{$b} <=> $stats{$a}} keys %stats;
	
	my %cws;
	
	foreach my $w (@sorted_words) {
		if ($stats{$w}/$n_words > HIGH_FREQUENCY_THR) {		
			next;
		} elsif ($stats{$w} >= MIN_FREQ) {
			$cws{$w} = 1;
		} else {
			last;
		}
	}
	
	print "Selected ".scalar(keys %cws)." content words.\n";
	
	return \%cws;
}


exit (main(@ARGV));

