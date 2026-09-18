-- A shipments table with defects planted on purpose. Every one of them is
-- invisible to SUMMARIZE: the types are right, the ranges are plausible, nothing
-- is NULL where it shouldn't be, and no distinct count looks strange.
--
-- Planted defects, by row id:
--   3, 17   test/placeholder rows that look like ordinary data
--   5, 12   country and postal code contradict each other
--   7, 15   status says shipped but shipped_at is empty
--   9       free-text note containing a national ID number
--   2, 11   weight mixes kg and lbs with no unit anywhere
--   14      an operational instruction typed into the address field
--   6       product name and category describe different things
--   19      sentinel date standing in for "unknown"
--   8       two email addresses crammed into one field
--   20      mojibake from a bad encoding round-trip

CREATE OR REPLACE TABLE shipments AS
SELECT * FROM (VALUES
 (1,'ORD-1001','Acme Industrial','ops@acme.com','1200 Harbor Blvd','Oakland','CA','94607','US','Steel Bracket','Hardware','12 kg',2,'delivered','2024-03-01','2024-03-02','standard handling'),
 (2,'ORD-1002','Nordwind GmbH','kontakt@nordwind.de','Hafenstrasse 14','Hamburg','HH','20457','DE','Copper Fitting','Hardware','26.4',1,'delivered','2024-03-01','2024-03-03','customer collected'),
 (3,'ORD-1003','Test Company','test@test.com','123 Main St','Test City','CA','00000','US','Test Product','Test','1 kg',1,'delivered','2024-03-02','2024-03-02','asdf'),
 (4,'ORD-1004','Harborline Ltd','post@harborline.co.uk','7 Dock Road','Bristol','ENG','BS1 6QH','GB','Steel Bracket','Hardware','9 kg',4,'delivered','2024-03-02','2024-03-04','none'),
 (5,'ORD-1005','Pacific Freight','hello@pacfreight.com','88 Quay Street','Auckland','AUK','SW1A 1AA','US','Rubber Seal','Hardware','3 kg',10,'delivered','2024-03-03','2024-03-05','none'),
 (6,'ORD-1006','Greenfield Co','sales@greenfield.com','22 Elm Avenue','Portland','OR','97205','US','Blue Cotton T-Shirt','Garden Tools','1 kg',6,'delivered','2024-03-03','2024-03-06','none'),
 (7,'ORD-1007','Acme Industrial','ops@acme.com','1200 Harbor Blvd','Oakland','CA','94607','US','Steel Bracket','Hardware','12 kg',3,'shipped','2024-03-04','','awaiting carrier scan'),
 (8,'ORD-1008','Delta Supplies','orders@delta.com; billing@delta.com','410 Pine Street','Seattle','WA','98101','US','Hex Nut','Hardware','0.5 kg',200,'delivered','2024-03-04','2024-03-06','none'),
 (9,'ORD-1009','Rivera Logistics','contact@rivera.mx','Av. Reforma 500','Mexico City','CMX','06600','MX','Copper Fitting','Hardware','5 kg',8,'delivered','2024-03-05','2024-03-08','consignee SSN 078-05-1120 on file for customs'),
 (10,'ORD-1010','Northgate Ltd','info@northgate.co.uk','15 Mill Lane','Leeds','ENG','LS1 4DY','GB','Rubber Seal','Hardware','2 kg',12,'delivered','2024-03-05','2024-03-07','none'),
 (11,'ORD-1011','Summit Tools','buy@summittools.com','900 Ridge Road','Denver','CO','80202','US','Steel Bracket','Hardware','35.2',5,'delivered','2024-03-06','2024-03-08','none'),
 (12,'ORD-1012','Bluewater Marine','sales@bluewater.com','3 Ocean Drive','Miami','FL','EC1A 1BB','US','Rubber Seal','Hardware','3 kg',7,'delivered','2024-03-06','2024-03-09','none'),
 (13,'ORD-1013','Acme Industrial','ops@acme.com','1200 Harbor Blvd','Oakland','CA','94607','US','Hex Nut','Hardware','0.5 kg',150,'delivered','2024-03-07','2024-03-09','none'),
 (14,'ORD-1014','Cedar Works','hello@cedarworks.com','DO NOT SHIP - see ticket 4412','Austin','TX','78701','US','Steel Bracket','Hardware','12 kg',2,'cancelled','2024-03-07','','account on hold'),
 (15,'ORD-1015','Harborline Ltd','post@harborline.co.uk','7 Dock Road','Bristol','ENG','BS1 6QH','GB','Copper Fitting','Hardware','5 kg',3,'shipped','2024-03-08','','none'),
 (16,'ORD-1016','Vista Components','orders@vista.com','55 Canyon Way','Phoenix','AZ','85004','US','Hex Nut','Hardware','0.5 kg',300,'delivered','2024-03-08','2024-03-10','none'),
 (17,'ORD-1017','Asdf Asdf','foo@bar.com','999 Fake Street','Springfield','ZZ','11111','US','Sample Item','Hardware','1 kg',1,'delivered','2024-03-09','2024-03-09','lorem ipsum dolor'),
 (18,'ORD-1018','Nordwind GmbH','kontakt@nordwind.de','Hafenstrasse 14','Hamburg','HH','20457','DE','Rubber Seal','Hardware','3 kg',9,'delivered','2024-03-09','2024-03-11','none'),
 (19,'ORD-1019','Lakeside Traders','ops@lakeside.com','12 Shore Road','Chicago','IL','60601','US','Steel Bracket','Hardware','12 kg',4,'delivered','2024-03-10','9999-12-31','delivery date not recorded'),
 (20,'ORD-1020','CafÃ© Lumière SARL','bonjour@cafelumiere.fr','8 Rue de la Paix','Paris','IDF','75002','FR','Copper Fitting','Hardware','5 kg',6,'delivered','2024-03-10','2024-03-12','livraison Ã  l''entrepÃ´t')
) AS t(id, order_ref, customer, email, address, city, region, postal_code, country,
       product_name, category, weight, qty, status, ordered_at, shipped_at, notes);
