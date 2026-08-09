import { mkdir, rename, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const CURRENT_WEATHER_URL =
  'https://data.weather.gov.hk/weatherAPI/opendata/weather.php?dataType=rhrread&lang=tc';
const FORECAST_URL =
  'https://data.weather.gov.hk/weatherAPI/opendata/weather.php?dataType=fnd&lang=tc';
const HKO_STATION = '香港天文台';

async function fetchJson(url) {
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`);
    return await response.json();
  } catch (error) {
    throw new Error(`${url}\n原因：${error.message}`, { cause: error });
  }
}

function stationReading(readings, label) {
  const reading = readings.find(({ place }) => place === HKO_STATION);

  if (!reading) {
    throw new Error(`Cannot find ${HKO_STATION} ${label} reading.`);
  }

  return reading.value;
}

let currentWeather;
let forecast;

const results = await Promise.allSettled([
    fetchJson(CURRENT_WEATHER_URL),
    fetchJson(FORECAST_URL),
]);
const failures = results.filter(({ status }) => status === 'rejected');

if (failures.length) {
  const details = failures.map(({ reason }) => `失敗 endpoint：${reason.message}`).join('\n');
  console.error(`\x1b[31m天氣資料更新失敗；保留現有 weather.json，沒有寫入任何資料。\n${details}\x1b[0m`);
  process.exitCode = 1;
} else {
  [currentWeather, forecast] = results.map(({ value }) => value);
}

if (process.exitCode) process.exit();

const weather = {
  // This is when this script retrieved the data, distinct from HKO's update time.
  fetchedAt: new Date().toISOString(),
  current: {
    temperature: stationReading(currentWeather.temperature.data, 'temperature'),
    humidity: stationReading(currentWeather.humidity.data, 'humidity'),
    warnings: currentWeather.warningMessage ?? [],
    hkoUpdateTime: currentWeather.updateTime,
  },
  forecast: forecast.weatherForecast.map((day) => ({
    date: day.forecastDate,
    weekday: day.week,
    description: day.forecastWeather,
    maxTemperature: day.forecastMaxtemp.value,
    minTemperature: day.forecastMintemp.value,
  })),
};

const outputPath = resolve(dirname(fileURLToPath(import.meta.url)), '../data/weather.json');
const temporaryPath = `${outputPath}.tmp`;
await mkdir(dirname(outputPath), { recursive: true });
await writeFile(temporaryPath, `${JSON.stringify(weather, null, 2)}\n`, 'utf8');
await rename(temporaryPath, outputPath);

console.log(`Weather data written to ${outputPath}`);
