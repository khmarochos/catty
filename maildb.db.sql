-- MySQL dump 8.23
--
-- Host: localhost    Database: maildb
---------------------------------------------------------
-- Server version	3.23.58

--
-- Table structure for table `transport`
--

CREATE TABLE transport (
  domain varchar(128) NOT NULL default '',
  transport varchar(128) NOT NULL default '',
  UNIQUE KEY domain (domain)
) TYPE=MyISAM;

--
-- Table structure for table `users`
--

CREATE TABLE users (
  id varchar(128) NOT NULL default '',
  address varchar(128) NOT NULL default '',
  crypt varchar(128) NOT NULL default '',
  clear varchar(128) NOT NULL default '',
  name varchar(128) NOT NULL default '',
  domain varchar(128) NOT NULL default '',
  maildir varchar(255) NOT NULL default '',
  imapok tinyint(3) unsigned NOT NULL default '1',
  quota bigint(20) unsigned NOT NULL default '0',
  PRIMARY KEY  (id),
  UNIQUE KEY address (address),
  UNIQUE KEY id (id),
  KEY id_2 (id),
  KEY address_2 (address)
) TYPE=MyISAM;

--
-- Table structure for table `virtual`
--

CREATE TABLE virtual (
  address varchar(255) NOT NULL default '',
  goto varchar(255) NOT NULL default '',
  UNIQUE KEY address (address)
) TYPE=MyISAM;

