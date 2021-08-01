const testFolder = './';
const fs = require('fs');

fs.readdirSync(testFolder).forEach(file => {
  const newFileName = file.replace("gallardus", "gallardo");
  fs.renameSync("./" + file, "./" + newFileName);
});