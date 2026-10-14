# Shared test-only budgets; local defaults remain strict, CI opts into slower hardware.
package Loomy::TestTiming;
use strict;
use warnings;
use POSIX qw(isfinite);
my $scale=$ENV{LOOMY_TEST_TIME_SCALE}//1;
die "invalid LOOMY_TEST_TIME_SCALE: expected a positive decimal\n"
    unless $scale =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ && $scale>0 && isfinite($scale);
sub budget {return $_[0]*$scale}
print budget($ARGV[0]//1),"\n" unless caller;
1;
