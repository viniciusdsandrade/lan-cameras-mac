#!/usr/bin/perl
# Procura classes de dado pessoal ou de instalação num fluxo de texto (stdin).
#
# Linhas "@@CTX <rótulo>" mudam o contexto (arquivo ou commit:arquivo); as demais
# são verificadas. Imprime só rótulo e categoria, NUNCA o texto encontrado, para
# que a saída da verificação não vire ela mesma um vazamento.
use strict;
use warnings;

my %ip_ok = map { $_ => 1 } ('127.0.0.1', '0.0.0.0', '239.255.255.250', '255.255.255.255');
my $ctx = '(sem contexto)';
my %visto;
my $achou = 0;

sub ip_permitido {
    my ($ip) = @_;
    return 1 if $ip_ok{$ip};
    # faixas reservadas para documentação (RFC 5737)
    return 1 if $ip =~ /^(?:192\.0\.2|198\.51\.100|203\.0\.113)\.\d+$/;
    return 0;
}

sub marca {
    my ($cat) = @_;
    $visto{"$ctx\t$cat"}++;
    $achou++;
}

while (my $l = <STDIN>) {
    chomp $l;
    if ($l =~ /^\@\@CTX (.*)$/) { $ctx = $1; next; }

    while ($l =~ /(?<![0-9.])((?:\d{1,3}\.){3}\d{1,3})(?![0-9.])/g) {
        my $ip = $1;
        next if grep { $_ > 255 } split /\./, $ip;
        marca('ipv4') unless ip_permitido($ip);
    }
    while ($l =~ /\b((?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2})\b/g) {
        my $m = lc $1;
        $m =~ s/-/:/g;
        marca('mac') unless $m =~ /^(?:02:00:00:|00:00:00:00:00:00)/;
    }
    marca('caminho-pessoal')
        if $l =~ m{/Users/(?!Shared\b)[A-Za-z0-9._-]+}
        || $l =~ m{/Volumes/\S}
        || $l =~ m{/home/[a-z][a-z0-9_-]*/};
    marca('senha-na-url')
        if $l =~ /(?:password|passwd|pwd)=(?!\*\*\*|<|\$|\{|%|\\\()[^\s&_"']{3,}/i;
    marca('usuario-na-url')
        if $l =~ /\buser=(?!\*\*\*|<|\$|\{|%|\\\()[^\s&_"']{3,}_/;
    while ($l =~ /([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})/g) {
        marca('email') unless $1 =~ /\@users\.noreply\.github\.com$/i;
    }
    while ($l =~ /\b([a-z0-9]{20,})\b/g) {
        my $t = $1;
        # serial de aparelho, hash ou chave: mistura de letras e dígitos
        marca('token-longo') if $t =~ /\d/ && $t =~ /[a-z]/;
    }
    marca('hostname-local') if $l =~ /\b[A-Za-z0-9][A-Za-z0-9-]*\.local\b/;
    marca('cpf') if $l =~ /\b\d{3}\.\d{3}\.\d{3}-\d{2}\b/;
    marca('telefone') if $l =~ /(?:\+55\s?)?\(?\b\d{2}\)?\s?9?\d{4}-\d{4}\b/;
}

for my $k (sort keys %visto) {
    my ($c, $cat) = split /\t/, $k, 2;
    printf "  %s: %s (%d)\n", $c, $cat, $visto{$k};
}
exit($achou ? 1 : 0);
