-- MySQL dump 8.23
--
-- Host: localhost    Database: catty
---------------------------------------------------------
-- Server version	3.23.58

--
-- Table structure for table `costs`
--

CREATE TABLE costs (
  cid bigint(20) unsigned NOT NULL auto_increment,
  ccode int(10) unsigned NOT NULL default '0',
  ctime decimal(7,2) NOT NULL default '0.00',
  ctimecb decimal(7,2) NOT NULL default '0.00',
  ctimecbd decimal(7,2) NOT NULL default '0.00',
  cinput decimal(7,2) NOT NULL default '0.00',
  cinputcb decimal(7,2) NOT NULL default '0.00',
  cinputcbd decimal(7,2) NOT NULL default '0.00',
  coutput decimal(7,2) NOT NULL default '0.00',
  coutputcb decimal(7,2) NOT NULL default '0.00',
  coutputcbd decimal(7,2) NOT NULL default '0.00',
  cmoment varchar(32) NOT NULL default 'Al0-24',
  corder tinyint(4) NOT NULL default '0',
  PRIMARY KEY  (cid)
) TYPE=MyISAM;

--
-- Table structure for table `managers`
--

CREATE TABLE managers (
  mid bigint(20) unsigned NOT NULL auto_increment,
  mlogin varchar(32) default NULL,
  mpasswd varchar(32) default NULL,
  mlevel int(10) unsigned default NULL,
  mname varchar(64) NOT NULL default '',
  mactive tinyint(4) NOT NULL default '1',
  mlastlogin datetime NOT NULL default '0000-00-00 00:00:00',
  PRIMARY KEY  (mid),
  UNIQUE KEY mlogin (mlogin)
) TYPE=MyISAM;

--
-- Table structure for table `nases`
--

CREATE TABLE nases (
  nid bigint(20) unsigned NOT NULL auto_increment,
  naddr varchar(15) NOT NULL default '',
  ncomm varchar(64) NOT NULL default '',
  nsrac tinyint(1) NOT NULL default '0',
  nntbc tinyint(3) unsigned NOT NULL default '0',
  ntype varchar(32) NOT NULL default '',
  nports tinyint(3) unsigned NOT NULL default '0',
  PRIMARY KEY  (nid),
  UNIQUE KEY naddr (naddr)
) TYPE=MyISAM;

--
-- Table structure for table `packages`
--

CREATE TABLE packages (
  kid bigint(20) unsigned NOT NULL auto_increment,
  kname varchar(64) NOT NULL default '',
  ktype tinyint(4) unsigned NOT NULL default '0',
  klogins tinyint(3) unsigned NOT NULL default '1',
  kthreshold tinyint(4) NOT NULL default '-1',
  kmute int(11) NOT NULL default '-1',
  kcb tinyint(3) unsigned NOT NULL default '0',
  PRIMARY KEY  (kid),
  UNIQUE KEY kname (kname)
) TYPE=MyISAM;

--
-- Table structure for table `packages_temp`
--

CREATE TABLE packages_temp (
  kid bigint(20) unsigned NOT NULL auto_increment,
  kname varchar(64) NOT NULL default '',
  ktype tinyint(4) unsigned NOT NULL default '0',
  klogins tinyint(3) unsigned NOT NULL default '1',
  kcb tinyint(3) unsigned NOT NULL default '0',
  PRIMARY KEY  (kid),
  UNIQUE KEY kname (kname)
) TYPE=MyISAM;

--
-- Table structure for table `payments`
--

CREATE TABLE payments (
  pid bigint(20) unsigned NOT NULL auto_increment,
  puser bigint(20) unsigned NOT NULL default '0',
  psum decimal(12,5) unsigned NOT NULL default '0.00000',
  ppaydate datetime NOT NULL default '2000-01-01 00:00:00',
  pcreate datetime NOT NULL default '2000-01-01 00:00:00',
  pexpire datetime NOT NULL default '2000-01-01 00:00:00',
  pmanager bigint(20) unsigned NOT NULL default '0',
  ppaid tinyint(1) unsigned NOT NULL default '0',
  paborted tinyint(1) unsigned NOT NULL default '0',
  ptype tinyint(1) unsigned NOT NULL default '0',
  ppack tinyint(1) unsigned NOT NULL default '0',
  PRIMARY KEY  (pid),
  KEY puser (puser),
  KEY p_1 (puser,ppack)
) TYPE=MyISAM;

--
-- Table structure for table `paytypes`
--

CREATE TABLE paytypes (
  ptid bigint(20) unsigned NOT NULL auto_increment,
  ptname varchar(32) default NULL,
  PRIMARY KEY  (ptid),
  UNIQUE KEY ptname (ptname)
) TYPE=MyISAM;

--
-- Table structure for table `ptypes`
--

CREATE TABLE ptypes (
  ktid tinyint(4) unsigned NOT NULL auto_increment,
  ktname varchar(16) NOT NULL default '',
  PRIMARY KEY  (ktid)
) TYPE=MyISAM;

--
-- Table structure for table `qreports`
--

CREATE TABLE qreports (
  qid int(4) NOT NULL auto_increment,
  qcaption varchar(64) NOT NULL default '',
  qdescription varchar(255) default NULL,
  qsql text NOT NULL,
  PRIMARY KEY  (qid)
) TYPE=MyISAM;

--
-- Table structure for table `sessions`
--

CREATE TABLE sessions (
  sid bigint(20) unsigned NOT NULL auto_increment,
  ssession varchar(32) NOT NULL default '',
  suser bigint(20) unsigned NOT NULL default '0',
  snas bigint(20) NOT NULL default '0',
  snasport varchar(16) NOT NULL default '',
  scsid varchar(16) NOT NULL default '',
  stime_start datetime default NULL,
  stime_stop datetime default NULL,
  straf_input int(10) unsigned NOT NULL default '0',
  straf_output int(10) unsigned NOT NULL default '0',
  scost decimal(12,5) unsigned NOT NULL default '0.00000',
  spack tinyint(4) NOT NULL default '0',
  PRIMARY KEY  (sid),
  UNIQUE KEY ssession (ssession),
  KEY suser (suser),
  KEY s_1 (suser,spack),
  KEY s_2 (stime_start)
) TYPE=MyISAM;

--
-- Table structure for table `sessions_agg`
--

CREATE TABLE sessions_agg (
  sid bigint(20) unsigned NOT NULL auto_increment,
  ssession varchar(32) NOT NULL default '',
  suser bigint(20) unsigned NOT NULL default '0',
  snas bigint(20) NOT NULL default '0',
  snasport varchar(16) NOT NULL default '',
  scsid varchar(16) NOT NULL default '',
  stime_start datetime default NULL,
  stime_stop datetime default NULL,
  straf_input int(10) unsigned NOT NULL default '0',
  straf_output int(10) unsigned NOT NULL default '0',
  scost decimal(12,5) unsigned NOT NULL default '0.00000',
  spack tinyint(4) NOT NULL default '0',
  PRIMARY KEY  (sid),
  UNIQUE KEY ssession (ssession),
  KEY suser (suser)
) TYPE=MyISAM;

--
-- Table structure for table `sessions_bak_20041227`
--

CREATE TABLE sessions_bak_20041227 (
  sid bigint(20) unsigned NOT NULL auto_increment,
  ssession varchar(32) NOT NULL default '',
  suser bigint(20) unsigned NOT NULL default '0',
  snas bigint(20) NOT NULL default '0',
  snasport varchar(16) NOT NULL default '',
  scsid varchar(16) NOT NULL default '',
  stime_start datetime default NULL,
  stime_stop datetime default NULL,
  straf_input int(10) unsigned NOT NULL default '0',
  straf_output int(10) unsigned NOT NULL default '0',
  scost decimal(12,5) unsigned NOT NULL default '0.00000',
  spack tinyint(4) NOT NULL default '0',
  PRIMARY KEY  (sid),
  UNIQUE KEY ssession (ssession),
  KEY suser (suser)
) TYPE=MyISAM;

--
-- Table structure for table `uattrs`
--

CREATE TABLE uattrs (
  uaid bigint(20) unsigned NOT NULL auto_increment,
  uadog bigint(20) unsigned NOT NULL default '0',
  uadate datetime NOT NULL default '0000-00-00 00:00:00',
  uafio varchar(128) NOT NULL default '',
  uaaddress varchar(255) default NULL,
  uafirmname varchar(255) NOT NULL default '',
  uaphone varchar(64) default NULL,
  uatype tinyint(1) NOT NULL default '0',
  uacomments text NOT NULL,
  PRIMARY KEY  (uaid),
  UNIQUE KEY uadog (uadog)
) TYPE=MyISAM;

--
-- Table structure for table `users`
--

CREATE TABLE users (
  uid bigint(20) unsigned NOT NULL auto_increment,
  uadog bigint(20) unsigned NOT NULL default '0',
  ulogin varchar(64) NOT NULL default '',
  uname varchar(64) NOT NULL default '',
  upack int(10) unsigned NOT NULL default '0',
  udbtr tinyint(3) unsigned NOT NULL default '0',
  udbtrd datetime NOT NULL default '2038-01-19 05:14:07',
  umanager bigint(10) unsigned NOT NULL default '0',
  ulevel tinyint(3) unsigned NOT NULL default '0',
  ucreate datetime NOT NULL default '2000-01-01 00:00:00',
  uexpire datetime NOT NULL default '2038-01-19 05:14:07',
  unotifyemail varchar(64) default NULL,
  unotified datetime NOT NULL default '2000-01-01 00:00:00',
  unotifiedc tinyint(3) unsigned NOT NULL default '0',
  udeleted tinyint(1) NOT NULL default '0',
  uslimit int(10) unsigned NOT NULL default '0',
  PRIMARY KEY  (uid),
  UNIQUE KEY ulogin (ulogin)
) TYPE=MyISAM;

