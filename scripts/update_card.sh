#!/bin/sh

wget --continue 'http://arpcard.mcmaster.ca/blast/db/protein/AR-polypeptides.fa.gz' 
#wget --continue 'http://arpcard.mcmaster.ca/blast/db/protein/AT-polypeptides.fa.gz'
#wget --continue 'http://arpcard.mcmaster.ca/blast/db/protein/ABS-polypeptides.fa.gz'
(
  #for i in AR-polypeptides.fa.gz AT-polypeptides.fa.gz ABS-polypeptides.fa.gz; 
  for i in AR-polypeptides.fa.gz
  do
    gunzip -c $i
  done;
) > CARD.faa
rm -vf AR-polypeptides.fa.gz AT-polypeptides.fa.gz ABS-polypeptides.fa.gz
legacy_blast.pl formatdb -i CARD.faa -p T
