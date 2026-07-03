import React from 'react';

export const metadata = {
  title: 'Cobrowse Agent',
  description: 'Cobrowsing dashboard для операторов',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ru">
      <body style={{ margin: 0, background: '#f9fafb' }}>{children}</body>
    </html>
  );
}
