INSERT IGNORE INTO vets VALUES (1, 'Cumhur', 'Akkaya');
INSERT IGNORE INTO vets VALUES (2, 'Erkut', 'Tursak');
INSERT IGNORE INTO vets VALUES (3, 'Taha', 'Akça');
INSERT IGNORE INTO vets VALUES (4, 'Rafael', 'Ortega');
INSERT IGNORE INTO vets VALUES (5, 'Henry', 'Stevens');
INSERT IGNORE INTO vets VALUES (6, 'Sharon', 'Jenkins');

INSERT IGNORE INTO specialties VALUES (1, 'Cloud');
INSERT IGNORE INTO specialties VALUES (2, 'DevOps');
INSERT IGNORE INTO specialties VALUES (3, 'Cloud infrastructure');

INSERT IGNORE INTO vet_specialties VALUES (1, 2);
INSERT IGNORE INTO vet_specialties VALUES (2, 3);
INSERT IGNORE INTO vet_specialties VALUES (3, 2);
INSERT IGNORE INTO vet_specialties VALUES (4, 2);
INSERT IGNORE INTO vet_specialties VALUES (5, 1);
INSERT IGNORE INTO vet_specialties VALUES (6, 3);
