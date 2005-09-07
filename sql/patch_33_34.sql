# SQL to patch a release 33 Ensembl database schema to release 34

ALTER table object_xref CHANGE COLUMN enembl_object_type ENUM( 'RawContig', 'Transcript', 'Gene', 'Translation', 'regulatory_factor', 'regulatory_feature' ) not null;

DROP TABLE regulatory_factor_transcript;

CREATE TABLE regulatory_factor_coding (

  regulatory_factor_id  INT NOT NULL,      # FK to regulatory_factor
  transcript_id         INT,               # FK to transcript
  gene_id         	INT,               # FK to gene

  KEY transcript_idx (transcript_id),
  KEY gene_idx (gene_id),
  KEY regulatory_factor_idx (regulatory_factor_id)

) COLLATE=latin1_swedish_ci TYPE=MyISAM;

