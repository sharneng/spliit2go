// Category IDs from Spliit seed migrations at commit
// cc796210db06bb112609f820c8eb8d7bbecdce83.
// https://github.com/spliit-app/spliit/blob/cc796210db06bb112609f820c8eb8d7bbecdce83/prisma/migrations/20240108194443_add_categories/migration.sql
// https://github.com/spliit-app/spliit/blob/cc796210db06bb112609f820c8eb8d7bbecdce83/prisma/migrations/20250308000000_add_category_donation/migration.sql
// Refresh from upstream migrations when categories change; this offline
// fixture checks known translations, not discovery of upstream additions.
const categorySeedIds = <int>[
  0, // Uncategorized/General
  1, // Uncategorized/Payment
  2, // Entertainment/Entertainment
  3, // Entertainment/Games
  4, // Entertainment/Movies
  5, // Entertainment/Music
  6, // Entertainment/Sports
  7, // Food and Drink/Food and Drink
  8, // Food and Drink/Dining Out
  9, // Food and Drink/Groceries
  10, // Food and Drink/Liquor
  11, // Home/Home
  12, // Home/Electronics
  13, // Home/Furniture
  14, // Home/Household Supplies
  15, // Home/Maintenance
  16, // Home/Mortgage
  17, // Home/Pets
  18, // Home/Rent
  19, // Home/Services
  20, // Life/Childcare
  21, // Life/Clothing
  22, // Life/Education
  23, // Life/Gifts
  24, // Life/Insurance
  25, // Life/Medical Expenses
  26, // Life/Taxes
  27, // Transportation/Transportation
  28, // Transportation/Bicycle
  29, // Transportation/Bus/Train
  30, // Transportation/Car
  31, // Transportation/Gas/Fuel
  32, // Transportation/Hotel
  33, // Transportation/Parking
  34, // Transportation/Plane
  35, // Transportation/Taxi
  36, // Utilities/Utilities
  37, // Utilities/Cleaning
  38, // Utilities/Electricity
  39, // Utilities/Heat/Gas
  40, // Utilities/Trash
  41, // Utilities/TV/Phone/Internet
  42, // Utilities/Water
  43, // Life/Donation
];
