// The poller v3 load-test fleet (SOLAR-656), one description for the database (fleet.sql's
// lt3.load) and the fake SunSynk (sunsynk.mjs). Plants 980000000.., share plants 981000000..
//   shape "3000": 2,700 logins x 1 plant x 2 inverters; 270 x 1 x 1; 25 x 3 plants x 6
//   inverters; 5 x 6 plants x 36 inverters; one share login with 500 plants, 1 inverter
//   each, claimed by 100 accounts of 5.  shape "<n>": n logins x 1 plant x 2 inverters.
export const SHARE_USERNAME = "ltshare";

export function fleet(shape) {
  const groups = shape === "3000"
    ? [[2700, 1, 2], [270, 1, 1], [25, 3, 2], [5, 6, 6]]
    : [[Number(shape), 1, 2]];
  const logins = [];
  let plant = 980000000, k = 0;
  for (const [n, plants, invs] of groups) {
    for (let i = 0; i < n; i++) {
      k++;
      logins.push({ username: `lt${k}`, plants: Array.from({ length: plants }, () => {
        plant++;
        return { id: plant, sns: Array.from({ length: invs }, (_, j) => `LT${plant}${String.fromCharCode(65 + j)}`) };
      }) });
    }
  }
  const share = shape === "3000"
    ? { username: SHARE_USERNAME, plants: Array.from({ length: 500 }, (_, j) => ({ id: 981000001 + j, sns: [`LS${981000001 + j}A`] })), claimers: 100 }
    : null;
  return { logins, share };
}
