UPDATE OR IGNORE `peer` SET ip = CAST(ip AS BLOB) WHERE typeof(ip) = 'text';
DELETE FROM `peer` WHERE typeof(ip) = 'text';
