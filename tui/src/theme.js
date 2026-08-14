// Carbonfox theme — based on the official Carbonfox colorscheme
const theme = {
  fg: '#e0e0e0',
  bg: '#161616',
  black: '#161616',
  red: '#ee5396',
  green: '#42be65',
  yellow: '#ffe97b',
  blue: '#33b1ff',
  magenta: '#be95ff',
  cyan: '#08bdba',
  white: '#dde1e6',
  brightBlack: '#525252',
  brightRed: '#ff7eb6',
  brightGreen: '#42be65',
  brightYellow: '#ffe97b',
  brightBlue: '#33b1ff',
  brightMagenta: '#be95ff',
  brightCyan: '#08bdba',
  brightWhite: '#f2f4f8',

  // Named semantic colors
  accent: '#33b1ff',
  accent2: '#08bdba',
  success: '#42be65',
  warning: '#ffe97b',
  error: '#ee5396',
  subtle: '#525252',
  surface: '#262626',
  surface2: '#393939',
  border: '#6f6f6f',
  highlight: '#0043ce',
  text: '#e0e0e0',
  textDim: '#a8a8a8',
  textBright: '#ffffff',
};

const widgetStyle = {
  border: { type: 'line', fg: theme.border },
  style: {
    fg: theme.text,
    bg: theme.bg,
    border: { fg: theme.border },
    label: { fg: theme.accent },
  },
};

module.exports = { theme, widgetStyle };
